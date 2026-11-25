import AppKit
import CoreGraphics
import IControlCore
@preconcurrency import WebKit

/// Captures only this app's events while its game window is key. The cursor is
/// disassociated from relative motion and restored on F8, blur and teardown.
@MainActor
final class FPSCaptureView: NSView {
    weak var controller: FPSController?
    private var monitor: Any?
    private var observers: [NSObjectProtocol] = []
    private var originalPointer: CGPoint?
    private var cursorHidden = false
    private var inputCaptured = false
    private var ignoredWarpMove = false
    private var lastMouseLocation: NSPoint?
    private var showingPointer = false
    private var pointerPressed = false
    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard controller?.enabled == true, controller?.ready == true, controller?.calibration == nil,
              controller?.isEditingLayout == false,
              bounds.contains(point) else { return nil }
        return self
    }
    override func mouseDown(with event: NSEvent) { controller?.capture() }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 100 { controller?.toggleCapture() }
    }

    func updateCapture(_ capture: Bool) {
        guard capture != inputCaptured else { return }
        if capture {
            guard let window, window.isKeyWindow, NSApp.isActive else { controller?.releaseCapture(); return }
            inputCaptured = true; window.makeFirstResponder(self); window.acceptsMouseMovedEvents = true
            originalPointer = CGEvent(source: nil)?.location
            let anchor = convert(NSPoint(x: bounds.midX, y: bounds.midY), to: nil)
            lastMouseLocation = anchor
            let point = window.convertPoint(toScreen: anchor)
            let top = NSScreen.screens.first?.frame.maxY ?? 0
            CGWarpMouseCursorPosition(CGPoint(x: point.x, y: top - point.y))
            if CGAssociateMouseAndMouseCursorPosition(0) != .success {
                restoreCursor(); controller?.releaseCapture(); return
            }
            NSCursor.hide(); cursorHidden = true; ignoredWarpMove = true
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged, .mouseMoved,
                .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp,
                .leftMouseDragged, .rightMouseDragged, .otherMouseDragged, .scrollWheel]) { [weak self] event in
                let consume = MainActor.assumeIsolated {
                    guard let self else { return false }
                    return self.handle(event) == nil
                }
                return consume ? nil : event
            }
            for name in [NSWindow.didResignKeyNotification, NSApplication.didResignActiveNotification,
                         NSApplication.willTerminateNotification, NSWorkspace.screensDidSleepNotification] {
                let center = name == NSWorkspace.screensDidSleepNotification ? NSWorkspace.shared.notificationCenter : NotificationCenter.default
                let observer = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        if name != NSWindow.didResignKeyNotification || (notification.object as? NSWindow) === self.window {
                            self.controller?.releaseCapture()
                        }
                    }
                }
                observers.append(observer)
            }
        } else { restoreCursor() }
    }

    func updateCursorMode(_ show: Bool) {
        guard inputCaptured, show != showingPointer else { return }
        showingPointer = show; pointerPressed = false; lastMouseLocation = nil
        if show {
            CGAssociateMouseAndMouseCursorPosition(1)
            if cursorHidden { NSCursor.unhide(); cursorHidden = false }
            NSCursor.arrow.set(); ignoredWarpMove = false
            if let window, let rect = controller?.renderedViewport {
                let local = NSPoint(x: rect.x + rect.width / 2, y: bounds.height - rect.y - rect.height / 2)
                let screen = window.convertPoint(toScreen: convert(local, to: nil))
                CGWarpMouseCursorPosition(.init(x: screen.x, y: (NSScreen.screens.first?.frame.maxY ?? 0) - screen.y))
                controller?.pointerMoved(.init(x: 0.5, y: 0.5))
            }
        } else {
            guard let window else { controller?.releaseCapture(); return }
            let anchor = convert(NSPoint(x: bounds.midX, y: bounds.midY), to: nil)
            lastMouseLocation = anchor
            let point = window.convertPoint(toScreen: anchor)
            let top = NSScreen.screens.first?.frame.maxY ?? 0
            CGWarpMouseCursorPosition(CGPoint(x: point.x, y: top - point.y))
            guard CGAssociateMouseAndMouseCursorPosition(0) == .success else { controller?.releaseCapture(); return }
            NSCursor.hide(); cursorHidden = true; ignoredWarpMove = true
        }
    }

    private func pointerPoint(_ event: NSEvent, clamp: Bool = false) -> FPSPoint? {
        let local = convert(event.locationInWindow, from: nil)
        return controller?.renderedViewport?.normalized(x: local.x, y: bounds.height - local.y, clamp: clamp)
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        guard inputCaptured, let controller else { return event }
        guard event.window === window, window?.isKeyWindow == true, NSApp.isActive else {
            controller.releaseCapture(); return event
        }
        if event.modifierFlags.contains(.command) { controller.releaseCapture(); return event }
        if controller.cursorMode, [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(event.type),
           !bounds.contains(convert(event.locationInWindow, from: nil)) {
            controller.releaseCapture(); return event
        }
        switch event.type {
        case .keyDown:
            if event.keyCode == 100 { controller.releaseCapture(); return nil }
            if !event.isARepeat, let code = FPSKey.macKeyCodes[event.keyCode] { controller.keyDown(code) }
        case .keyUp:
            if let code = FPSKey.macKeyCodes[event.keyCode] { controller.keyUp(code) }
        case .flagsChanged:
            for (flag, code) in [(NSEvent.ModifierFlags.shift, "Shift"), (.control, "Control"), (.option, "Option")] {
                if event.modifierFlags.contains(flag) { controller.keyDown(code) } else { controller.keyUp(code) }
            }
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            if controller.cursorMode {
                if let point = pointerPoint(event, clamp: pointerPressed) { controller.pointerMoved(point) }
                else { controller.pointerHoverOutside() }
                break
            }
            let location = event.locationInWindow
            defer { lastMouseLocation = location }
            if ignoredWarpMove { ignoredWarpMove = false; break }
            var dx = event.cgEvent?.getDoubleValueField(.mouseEventDeltaX) ?? event.deltaX
            var dy = event.cgEvent?.getDoubleValueField(.mouseEventDeltaY) ?? event.deltaY
            if dx == 0, dy == 0 { dx = event.deltaX; dy = event.deltaY }
            // Absolute pointing devices and accessibility input may omit relative
            // deltas. Physical mouse deltas remain authoritative while captured.
            if dx == 0, dy == 0, let previous = lastMouseLocation {
                dx = location.x - previous.x; dy = previous.y - location.y
            }
            controller.mouse(dx: dx, dy: dy)
        case .leftMouseDown:
            lastMouseLocation = event.locationInWindow
            if controller.cursorMode {
                if let point = pointerPoint(event) { pointerPressed = true; controller.pointerDown(point) }
            } else { controller.keyDown("MouseLeft") }
        case .leftMouseUp:
            lastMouseLocation = event.locationInWindow
            if controller.cursorMode {
                if pointerPressed, let point = pointerPoint(event, clamp: true) { controller.pointerMoved(point) }
                pointerPressed = false; controller.pointerUp()
            }
            else { controller.keyUp("MouseLeft") }
        case .rightMouseDown:
            lastMouseLocation = event.locationInWindow
            if !controller.cursorMode { controller.keyDown("MouseRight") }
        case .rightMouseUp:
            lastMouseLocation = event.locationInWindow
            if !controller.cursorMode { controller.keyUp("MouseRight") }
        case .otherMouseDown:
            lastMouseLocation = event.locationInWindow
            if !controller.cursorMode, let code = FPSKey.mouseButton(event.buttonNumber) { controller.keyDown(code) }
        case .otherMouseUp:
            lastMouseLocation = event.locationInWindow
            if !controller.cursorMode, let code = FPSKey.mouseButton(event.buttonNumber) { controller.keyUp(code) }
        case .scrollWheel: controller.scroll(event.scrollingDeltaY)
        default: return event
        }
        return nil
    }
    func restoreCursor() {
        guard inputCaptured || originalPointer != nil || cursorHidden || monitor != nil else { return }
        inputCaptured = false
        showingPointer = false; pointerPressed = false
        lastMouseLocation = nil; ignoredWarpMove = false
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        for observer in observers {
            NotificationCenter.default.removeObserver(observer); NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        observers.removeAll()
        CGAssociateMouseAndMouseCursorPosition(1)
        if let originalPointer { CGWarpMouseCursorPosition(originalPointer); self.originalPointer = nil }
        if cursorHidden { NSCursor.unhide(); cursorHidden = false }
    }
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { controller?.releaseCapture(); restoreCursor() }
        super.viewWillMove(toWindow: newWindow)
    }
}

@MainActor
final class ViewerContainer: NSView {
    let webView: WKWebView
    let gameCapture = FPSCaptureView()
    init(webView: WKWebView) {
        self.webView = webView; super.init(frame: .zero)
        for child in [webView, gameCapture] as [NSView] {
            child.frame = bounds; child.autoresizingMask = [.width, .height]; addSubview(child)
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
