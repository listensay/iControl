import AppKit
import Combine
import IControlCore
@preconcurrency import WebKit

/// One gate for entry, pending WebKit replies, and every captured event. Identity
/// matters: a reconnect/device switch can change the session without changing a Bool.
struct EdgePointerSession: Equatable {
    let device: String
    let url: URL
    let attempt: Int

    @MainActor static func current(for model: ControlModel) -> Self? {
        let fps = model.fpsController
        guard model.wantsConnection, model.viewerConnected, fps.videoReady, model.phase == .connected, let url = model.viewerURL,
              !model.fpsUpdaterOnly, !model.showInstaller, !model.showTextSender, !model.showPasswordPrompt,
              !fps.enabled, !fps.captured, !fps.cursorMode, !fps.isEditingLayout, !fps.layoutTesting,
              !fps.layoutSaving, fps.calibration == nil, !fps.showSettings else { return nil }
        return Self(device: model.selectedUDID, url: url, attempt: model.connectionAttempt)
    }
}

@MainActor
final class EdgePointerController: ObservableObject {
    @Published var enabled = UserDefaults.standard.bool(forKey: "edgePointer.enabled") {
        didSet {
            UserDefaults.standard.set(enabled, forKey: "edgePointer.enabled")
            updateWatch()
        }
    }
    @Published var side = EdgePointerSide(rawValue: UserDefaults.standard.string(forKey: "edgePointer.side") ?? "") ?? .right {
        didSet { UserDefaults.standard.set(side.rawValue, forKey: "edgePointer.side"); release() }
    }
    @Published var zone = EdgePointerZone(rawValue: UserDefaults.standard.string(forKey: "edgePointer.zone") ?? "") ?? .full {
        didSet { UserDefaults.standard.set(zone.rawValue, forKey: "edgePointer.zone"); release() }
    }
    @Published private(set) var session: EdgePointerSession?
    @Published private(set) var controlling = false
    @Published private(set) var problem: String?

    private weak var model: ControlModel?
    private var clock: Timer?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var monitor: Any?
    private var armed = false
    private var dwell: TimeInterval?
    private var ride: Ride?
    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    private final class Ride {
        let channel: EdgePointerChannel, seam: EdgePointerSeam
        weak var window: NSWindow?
        var point: CGPoint, space: CGSize?
        var lastAck: TimeInterval, lastSend: TimeInterval = 0, capturedAt: TimeInterval = 0
        var previousMoves = false, parked = false, ownsCursor = false, skipFirstDelta = true
        var pressed = false, dirty = false, pending = 0
        var scroll: CGFloat = 0
        var cursorPoint: FPSPoint { FPSPoint(x: min(1, max(0, point.x)), y: min(1, max(0, point.y))) }
        init(_ channel: EdgePointerChannel, window: NSWindow, seam: EdgePointerSeam, point: CGPoint, now: TimeInterval) {
            self.channel = channel; self.window = window; self.seam = seam; self.point = point; lastAck = now
        }
    }

    func synchronize(with model: ControlModel) {
        let next = EdgePointerSession.current(for: model)
        if self.model !== model || session != next {
            release(); self.model = model; session = next
        }
        updateWatch()
    }

    /// Call on window destruction / before shutting down the viewer transport.
    func detach() {
        release(); model = nil; session = nil; updateWatch()
    }

    private func updateWatch() {
        guard enabled, session != nil else {
            release(); clock?.invalidate(); clock = nil
            for (center, token) in observers { center.removeObserver(token) }
            observers.removeAll(); return
        }
        guard clock == nil else { return }
        // Only poll position in our active key window's session. No event tap,
        // global input monitor, Accessibility grant, or posted input events.
        let timer = Timer(timeInterval: 1 / 30.0, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                if let self { self.tick() } else { timer.invalidate() }
            }
        }
        timer.tolerance = 0.004; clock = timer
        RunLoop.main.add(timer, forMode: .default) // never arm in menu/modal tracking loops
        func observe(_ center: NotificationCenter, _ name: Notification.Name) {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if let w = note.object as? NSWindow, w !== self.ride?.window && w !== self.model?.viewerDriver.webView?.window { return }
                    if name == NSWindow.willCloseNotification || name == NSApplication.willTerminateNotification { self.detach() }
                    else { self.release() }
                }
            }
            observers.append((center, token))
        }
        for name in [NSWindow.didResignKeyNotification, NSWindow.willCloseNotification, NSWindow.willMiniaturizeNotification,
                     NSWindow.didMoveNotification, NSWindow.didResizeNotification, NSWindow.willBeginSheetNotification,
                     NSApplication.willResignActiveNotification,
                     NSApplication.didChangeScreenParametersNotification, NSApplication.willTerminateNotification,
                     NSMenu.didBeginTrackingNotification] { observe(.default, name) }
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification,
                     NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.activeSpaceDidChangeNotification] {
            observe(NSWorkspace.shared.notificationCenter, name)
        }
    }

    private var keyViewer: WKWebView? {
        guard enabled, let model, let session, session == EdgePointerSession.current(for: model),
              NSApp.isActive, NSApp.modalWindow == nil, let view = model.viewerDriver.webView,
              let w = view.window, w.isKeyWindow, w.attachedSheet == nil, w.isVisible, w.isOnActiveSpace,
              !w.isMiniaturized, w.occlusionState.contains(.visible), !view.visibleRect.isEmpty else { return nil }
        return view
    }

    private func tick() {
        guard let view = keyViewer, let window = view.window, let screen = window.screen else { release(); return }
        let seam = EdgePointerSeam(side: side, frame: screen.frame, zone: zone)
        if let r = ride {
            guard r.channel.view === view, r.window === window, r.seam == seam else { release(); return }
            guard now - r.lastAck < 1.3 else { fail("画面未响应，鼠标已返回 Mac。"); return }
            if r.pressed, NSEvent.pressedMouseButtons & 1 == 0 {
                // Recover a lost local mouseUp; don't keep renewing a stationary touch.
                r.pressed = false; send(r)
            } else if r.ownsCursor, r.pending == 0, r.dirty || now - r.lastSend >= 0.4 { send(r) }
            return
        }
        guard NSEvent.pressedMouseButtons == 0, !NSEvent.modifierFlags.contains(.command) else { disarm(); return }
        let p = NSEvent.mouseLocation
        if seam.frame.contains(p), seam.distanceInside(p) > 16 { armed = true }
        guard armed, let entry = seam.entry(at: p, screens: NSScreen.screens) else { dwell = nil; return }
        if let dwell {
            guard now - dwell >= 0.15 else { return }
            begin(window: window, seam: seam, point: entry)
        } else { dwell = now }
    }

    private func begin(window: NSWindow, seam: EdgePointerSeam, point: CGPoint) {
        guard ride == nil, let channel = model?.viewerDriver.edgePointerChannel() else { return }
        disarm(); problem = nil
        let r = Ride(channel, window: window, seam: seam, point: point, now: now)
        ride = r
        channel.begin(at: point) { [weak self, weak r] size in
            guard let self, let r, self.ride === r else { return }
            guard let size else { self.fail("画面尚不能接收指针，请离开边缘后重试。"); return }
            self.capture(r, framebuffer: size)
        }
    }

    private func capture(_ r: Ride, framebuffer: CGSize) {
        guard now - r.lastAck < 1.3, let view = keyViewer, view === r.channel.view, let w = view.window, w === r.window,
              w.screen?.frame == r.seam.frame, NSEvent.pressedMouseButtons == 0,
              !NSEvent.modifierFlags.contains(.command),
              r.seam.entry(at: NSEvent.mouseLocation, screens: NSScreen.screens) != nil else { release(); return }
        let rect = view.visibleRect
        let anchor = w.convertPoint(toScreen: view.convert(CGPoint(x: rect.midX, y: rect.midY), to: nil))
        // A key window can be partly covered (e.g. Picture in Picture). Do not park
        // a hidden cursor over someone else's window and let clicks through to it.
        guard NSWindow.windowNumber(at: anchor, belowWindowWithWindowNumber: 0) == w.windowNumber else {
            fail("请先移开遮住 iPad 预览的窗口。"); return
        }
        guard EdgePointerSeam.warp(to: anchor) else { fail("Mac 未允许定位鼠标，未进入 iPad。"); return }
        r.parked = true
        guard CGAssociateMouseAndMouseCursorPosition(0) == .success else { fail("Mac 未允许相对鼠标输入，已取消跨屏。"); return }
        r.previousMoves = w.acceptsMouseMovedEvents; w.acceptsMouseMovedEvents = true
        NSCursor.hide(); r.ownsCursor = true; r.space = r.seam.virtualSize(framebuffer: framebuffer)
        r.capturedAt = now; r.lastAck = now; r.lastSend = now
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
            .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp, .scrollWheel,
            .keyDown, .flagsChanged]) { [self] event in
            // Keep the cursor owner alive until release removes this monitor. Even
            // unexpected loss of the model then fails the next keyViewer check.
            let consumed = MainActor.assumeIsolated { self.consume(event) }
            return consumed ? nil : event
        }
        guard monitor != nil else { fail("无法接收窗口鼠标事件，已取消跨屏。"); return }
        controlling = true
        model?.fpsController.beginEdgeCursor(at: r.cursorPoint)
    }

    private func consume(_ event: NSEvent) -> Bool {
        guard let r = ride, r.ownsCursor, let space = r.space else { return false }
        guard let view = keyViewer, view === r.channel.view, event.window === r.window else { release(); return false }
        guard event.timestamp >= r.capturedAt else { return true }
        if event.modifierFlags.contains(.command) { release(); return false }
        switch event.type {
        case .keyDown:
            if event.keyCode == 53 { release(); return true } // local Esc only
            return false
        case .flagsChanged: return false
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            if r.skipFirstDelta { r.skipFirstDelta = false; return true }
            var dx = event.cgEvent?.getDoubleValueField(.mouseEventDeltaX) ?? event.deltaX
            var dy = event.cgEvent?.getDoubleValueField(.mouseEventDeltaY) ?? event.deltaY
            if dx == 0 && dy == 0 { dx = event.deltaX; dy = event.deltaY }
            guard dx.isFinite, dy.isFinite else { release(); return true }
            if r.seam.advance(&r.point, dx: dx, dy: dy, space: space) { release() }
            else { r.dirty = true }
        case .leftMouseDown, .leftMouseUp:
            r.pressed = event.type == .leftMouseDown; send(r) // never coalesce down/up
        case .rightMouseDown: release() // emergency exit even without a keyboard
        case .scrollWheel:
            guard !r.pressed, event.momentumPhase.isEmpty else { return true }
            let step: CGFloat = event.hasPreciseScrollingDeltas ? 32 : 1
            r.scroll += event.scrollingDeltaY
            if abs(r.scroll) >= step { send(r, wheel: r.scroll > 0 ? 8 : 16); r.scroll = 0 }
        default: break // don't leak auxiliary buttons to the parked window
        }
        return true
    }

    private func send(_ r: Ride, wheel: Int = 0) {
        guard r.pending < 8 else { fail("画面输入积压，鼠标已返回 Mac。"); return }
        model?.fpsController.moveEdgeCursor(to: r.cursorPoint)
        r.dirty = false; r.pending += 1; r.lastSend = now
        r.channel.send(r.point, pressed: r.pressed, wheel: wheel) { [weak self, weak r] ok in
            guard let self, let r, self.ride === r else { return }
            r.pending -= 1
            if ok { r.lastAck = self.now } else { self.fail("画面或连接已变化，鼠标已返回 Mac。") }
        }
    }

    private func disarm() { armed = false; dwell = nil }
    private func fail(_ message: String) { release(); problem = message }

    /// Idempotent. Never undo the FPS controller's independent capture or send
    /// an up through a replacement WKWebView. Local recovery needs no JS reply.
    func release() {
        disarm()
        guard let r = ride else { return }
        ride = nil; r.channel.end(at: r.point)
        model?.fpsController.endEdgeCursor()
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        let gameOwnsCursor = model?.fpsController.captured == true
        if r.ownsCursor, !gameOwnsCursor {
            CGAssociateMouseAndMouseCursorPosition(1)
            r.window?.acceptsMouseMovedEvents = r.previousMoves
        }
        if r.parked, !gameOwnsCursor, NSApp.isActive, r.window?.isKeyWindow == true,
           NSScreen.screens.contains(where: { $0.frame == r.seam.frame }) {
            _ = EdgePointerSeam.warp(to: r.seam.macPoint(for: r.point))
        }
        if r.ownsCursor { NSCursor.unhide() }
        if controlling { controlling = false }
    }
}
