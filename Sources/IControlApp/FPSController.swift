import Foundation
import SwiftUI
import AppKit
import IControlCore

@MainActor
final class FPSController: ObservableObject {
    @Published var enabled = false {
        willSet { if newValue && !enabled { beforeGameMode?() } }
        didSet { if !enabled { calibration = nil; cancelLayoutEditing(); stopLink() }; synchronize() }
    }
    var beforeGameMode: (() -> Void)?
    @Published private(set) var directView = false
    var canPauseMirroring: Bool { enabled && ready && videoReady && !isEditingLayout && calibration == nil }
    func setDirectView(_ on: Bool) {
        guard directView != on, !on || canPauseMirroring else { return }
        directView = on
        visualsChanged?()
    }
    @Published private(set) var ready = false
    @Published private(set) var connecting = false
    @Published private(set) var captured = false
    @Published private(set) var cursorMode = false
    @Published private(set) var deviceCursorAvailable = false
    @Published private(set) var deviceCursorVisible = false
    @Published private(set) var supportsDeviceCursor = false
    @Published private(set) var videoReady = false
    @Published private(set) var viewportAspect = 4.0 / 3.0
    @Published private(set) var status = "进入游戏后开启 FPS 模式。"
    @Published private(set) var roundTripMilliseconds: Double?
    @Published private(set) var remoteContacts = 0
    @Published private(set) var remoteOrientation = 0
    @Published private(set) var hasRemoteOrientation = false
    @Published private(set) var lastAction = ""
    @Published var showSettings = false { didSet { if showSettings { releaseCapture() } } }
    @Published var showMarkers = true { didSet { visualsChanged?() } }
    @Published private(set) var calibration: String?
    @Published private(set) var layoutEditor: FPSLayoutEditor? { didSet { visualsChanged?() } }
    @Published private(set) var layoutError: String?
    @Published private(set) var layoutTesting = false
    @Published private(set) var layoutSaving = false
    @Published private(set) var layoutTestMessage: String?
    @Published var profile: FPSProfile { didSet { if profile != oldValue { profileChanged() } } }
    @Published private(set) var library: FPSProfileLibrary
    var captureChanged: ((Bool) -> Void)?
    var cursorModeChanged: ((Bool) -> Void)?
    var visualsChanged: (() -> Void)?
    var log: ((String) -> Void)?

    private let mux: USBMux
    private let isDemo: Bool
    private let libraryURL: URL
    private var device: USBDevice?
    private var accessToken = ""
    private var sessionTokens: [String: String] = [:]
    // Ordinary cross-screen clicks use VNC. When this iPad also has the cursor
    // service installed, borrow the same authenticated link for a visible dot.
    private var edgeCursorPoint: FPSPoint?
    private var needsInputLink: Bool { enabled || edgeCursorPoint != nil }
    private var link: FPSUSBLink?
    // Only AppKit/SwiftUI feedback is resolved here. The link owns gameplay state.
    private var keyFeedback: [String: (action: String?, togglesCursor: Bool)] = [:]
    private var physicalKeysDown = Set<String>()
    private(set) var renderedViewport: FPSViewport?
    private var epoch = UUID()
    private var lastAttempt: TimeInterval = 0
    private var editingSelection = false
    private var lastScroll: TimeInterval = 0
    private var layoutSession = ""
    private var layoutSequence = 0
    private var layoutDeviceUDID: String?
    private var layoutTestTask: Task<Void, Never>?
    private var layoutTestEpoch = UUID()

    init(mux: USBMux, isDemo: Bool, selectedDevice: String) {
        self.mux = mux; self.isDemo = isDemo
        libraryURL = isDemo
            ? (Bundle.main.object(forInfoDictionaryKey: "IControlDemoFPSProfiles") as? String).map { URL(fileURLWithPath: $0) }
                ?? URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("icontrol-fps-qa-\(UUID().uuidString).json")
            : AppResources.support.appendingPathComponent("fps-profiles.json")
        let loaded = (try? FPSProfileLibrary.load(from: libraryURL)) ?? FPSProfileLibrary()
        library = loaded
        profile = loaded.profiles.first(where: { $0.id == loaded.selectionByDevice[selectedDevice] }) ?? loaded.profiles[0]
    }
    var profileNames: [FPSProfile] { library.profiles }
    var selectedProfileID: UUID { profile.id }
    var isEditingLayout: Bool { layoutEditor != nil }
    private var aspect: Double { viewportAspect }
    var orientationDescription: String {
        let video = aspect > 1 ? "横屏" : "竖屏"
        guard hasRemoteOrientation else { return "画面：\(video) · 等待控制端方向" }
        let mismatch = (aspect > 1) != (remoteOrientation % 2 == 1)
        return "画面：\(video) · 控制端：\(remoteOrientation * 90)°" + (mismatch ? " · 方向不一致，请选择画面方向" : "")
    }
    var calibrationTitle: String {
        if calibration == "joystick" { return "移动摇杆中心" }
        if calibration == "look" { return "转向区域中心" }
        return profile.buttons.first(where: { $0.id == calibration })?.title ?? "触控位置"
    }
    var tokenForInstallation: String? { accessToken.isEmpty ? nil : accessToken }
    var deviceCursorHint: String {
        if deviceCursorAvailable { return "iPad 游戏画面指针已就绪" }
        return supportsDeviceCursor ? "iPad 指针显示进程未就绪；若呼出后仍不显示，请在安装器中更新至 1.4.1"
            : "iPad 指针需安装 / 配置 1.4.0 控制端"
    }

    func update(device: USBDevice?, videoReady: Bool) {
        let changed = self.device?.udid != device?.udid || self.device?.deviceID != device?.deviceID
        if changed {
            if let device, let layoutDeviceUDID, device.udid != layoutDeviceUDID { cancelLayoutEditing() }
            stopLink(); calibration = nil; self.device = device; accessToken = ""; lastAttempt = 0
            if let device {
                let selected = library.selectionByDevice[device.udid]
                if let saved = library.profiles.first(where: { $0.id == selected }) {
                    editingSelection = true; profile = saved; editingSelection = false
                }
                if isDemo { accessToken = Bundle.main.object(forInfoDictionaryKey: "IControlDemoGameToken") as? String ?? "" }
                else if let token = sessionTokens[device.udid] { accessToken = token }
                else {
                    Task { [weak self] in
                        let result = await Task.detached(priority: .userInitiated) {
                            Result { try PasswordStore.load(device: FPSAccessToken.keychainAccount(device: device.udid)) }
                        }.value
                        guard let self, self.device?.udid == device.udid,
                              self.device?.deviceID == device.deviceID, self.accessToken.isEmpty else { return }
                        switch result {
                        case .success(let token): self.accessToken = token ?? ""
                        case .failure(let error): self.log?(error.localizedDescription)
                        }
                        self.synchronize()
                    }
                }
            }
        }
        if self.videoReady != videoReady { self.videoReady = videoReady }
        if !videoReady {
            renderedViewport = nil
            if link != nil || connecting || captured { stopLink() }
        }
        synchronize()
    }

    func rememberToken(_ token: String, device: USBDevice, remember: Bool) {
        accessToken = token
        sessionTokens[device.udid] = token
        if !isDemo {
            do {
                if remember { try PasswordStore.save(token, device: FPSAccessToken.keychainAccount(device: device.udid)) }
                else { try PasswordStore.remove(device: FPSAccessToken.keychainAccount(device: device.udid)) }
            } catch { log?(error.localizedDescription) }
        }
        self.device = device; lastAttempt = 0
    }

    func forgetToken(device udid: String) {
        sessionTokens.removeValue(forKey: udid)
        if device?.udid == udid { stopLink(); accessToken = "" }
        if !isDemo {
            do { try PasswordStore.remove(device: FPSAccessToken.keychainAccount(device: udid)) }
            catch { log?(error.localizedDescription) }
        }
    }

    func synchronize() {
        visualsChanged?()
        guard needsInputLink else {
            if status != "进入游戏后开启 FPS 模式。" { status = "进入游戏后开启 FPS 模式。" }
            return
        }
        guard videoReady, let device else {
            let message = isEditingLayout ? "画面已断开，布局草稿已保留，可保存或等待重连。" : "先连接 iPad 画面，再进入游戏。"
            if status != message { status = message }
            return
        }
        guard (try? FPSAccessToken.bytes(accessToken)) != nil else {
            if status != "请安装 / 配置新版 FPS 控制端。" { status = "请安装 / 配置新版 FPS 控制端。" }
            return
        }
        guard !ready, !connecting, ProcessInfo.processInfo.systemUptime - lastAttempt > 3 else { return }
        connecting = true; status = "正在连接 USB 多点触摸通道…"
        lastAttempt = ProcessInfo.processInfo.systemUptime
        let currentEpoch = epoch, mux = self.mux, token = accessToken
        let notify: @Sendable (FPSLinkEvent) -> Void = { [weak self] event in
            guard let self else { return }
            Task { @MainActor in self.linkEvent(event, epoch: currentEpoch) }
        }
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                Result {
                    try FPSUSBLink.connect(mux: mux, device: device, token: token, callback: notify)
                }
            }.value
            guard epoch == currentEpoch, needsInputLink, videoReady else {
                if case .success(let abandoned) = result { abandoned.stop() }; return
            }
            connecting = false
            switch result {
            case .success(let link):
                self.link = link; supportsDeviceCursor = link.supportsDeviceCursor; ready = true
                status = isEditingLayout ? "拖动按键移动位置，拖动角点调整大小。" : "点击画面或按 F8 捕获鼠标；F8 释放。"
                if let edgeCursorPoint { link.setDeviceCursor(.init(point: edgeCursorPoint)) }
                log?("FPS USB 多点触摸通道已连接。")
            case .failure(let error): status = error.localizedDescription
            }
        }
    }

    private func linkEvent(_ event: FPSLinkEvent, epoch: UUID) {
        guard self.epoch == epoch else { return }
        switch event {
        case .acknowledgement(let milliseconds, let contacts, let orientation):
            if directView, profile.orientation == .automatic, hasRemoteOrientation, remoteOrientation != orientation {
                setDirectView(false); releaseCapture()
                status = "iPad 方向已变化，已恢复投屏。确认布局后可重新捕获。"
            }
            if remoteOrientation != orientation { remoteOrientation = orientation }
            if !hasRemoteOrientation { hasRemoteOrientation = true }
            guard enabled, !showSettings, !isEditingLayout else { return }
            roundTripMilliseconds = milliseconds
            if remoteContacts != contacts { remoteContacts = contacts }
        case .failed(let message):
            stopLink(); status = message; log?(message)
        case .deviceCursor(let available, let visible):
            if deviceCursorAvailable != available { deviceCursorAvailable = available }
            if deviceCursorVisible != visible { deviceCursorVisible = visible }
            if cursorMode { updateCursorStatus() }
        }
    }

    func beginEdgeCursor(at point: FPSPoint) {
        guard !enabled, videoReady, point.isValid else { return }
        edgeCursorPoint = point
        synchronize()
    }
    func moveEdgeCursor(to point: FPSPoint) {
        guard !enabled, edgeCursorPoint != nil, point.isValid, point != edgeCursorPoint else { return }
        edgeCursorPoint = point
        link?.setDeviceCursor(.init(point: point))
    }
    func endEdgeCursor() {
        guard edgeCursorPoint != nil else { return }
        edgeCursorPoint = nil
        if !enabled { stopLink() }
    }

    func toggleCapture() { captured ? releaseCapture() : capture() }
    func capture() {
        guard enabled, ready, videoReady, calibration == nil, !isEditingLayout, !showSettings, !captured,
              let link else { return }
        do {
            try link.startCapture(profile: profile, aspect: aspect)
            prepareKeyFeedback()
            captured = true; cursorMode = false
            status = "游戏输入已捕获 · \(FPSKey.title(profile.cursorToggleKey)) 呼出鼠标 · F8 释放"
            captureChanged?(true); visualsChanged?()
        } catch { status = error.localizedDescription }
    }
    private func prepareKeyFeedback() {
        let buttons = profile.buttons.filter(\.enabled)
        for code in FPSKey.choices {
            let linked = Set(profile.linkedKeys(from: code))
            let titles = buttons.compactMap { linked.contains($0.trigger) ? $0.title : nil }
            let togglesCursor = linked.contains(FPSKey.cursorAction)
            if togglesCursor || !titles.isEmpty {
                let action = titles.isEmpty ? nil : "\(titles.joined(separator: " + ")) · \(FPSKey.title(code))"
                keyFeedback[code] = (action, togglesCursor)
            }
        }
    }
    func releaseCapture() {
        link?.releaseAll()
        let wasCaptured = captured; captured = false; cursorMode = false
        physicalKeysDown.removeAll(); keyFeedback.removeAll(); lastScroll = 0
        if !lastAction.isEmpty { lastAction = "" }
        if wasCaptured { captureChanged?(false); visualsChanged?() }
        if ready, !isEditingLayout { status = "输入已释放；点击画面或按 F8 继续。" }
    }
    func keyDown(_ code: String) {
        // Linked cursor actions are edges, not repeats while the source is held.
        guard captured, physicalKeysDown.insert(code).inserted else { return }
        if code == profile.cursorToggleKey { toggleCursorMode(); return }
        link?.key(code, down: true)
        if let feedback = keyFeedback[code] {
            if let action = feedback.action, lastAction != action { lastAction = action }
            if feedback.togglesCursor { toggleCursorMode() }
        }
    }
    func keyUp(_ code: String) {
        guard captured, physicalKeysDown.remove(code) != nil, code != profile.cursorToggleKey else { return }
        link?.key(code, down: false)
    }
    func toggleCursorMode() {
        guard captured else { return }
        let next = !cursorMode
        link?.cursorMode(next)
        // Changing mode releases gameplay mouse buttons; their ups may now be pointer events.
        physicalKeysDown = physicalKeysDown.filter { !$0.hasPrefix("Mouse") }
        cursorMode = next; cursorModeChanged?(next); visualsChanged?()
        guard captured else { return }
        if next { updateCursorStatus() }
        else { status = "游戏输入已捕获 · \(FPSKey.title(profile.cursorToggleKey)) 呼出鼠标 · F8 释放" }
    }
    func showGameCursor() {
        if !captured { capture() }
        if captured, !cursorMode { toggleCursorMode() }
    }
    private func updateCursorStatus() {
        let location = deviceCursorVisible ? "Mac / iPad 鼠标已呼出"
            : deviceCursorAvailable ? "Mac 鼠标已呼出 · 正在显示 iPad 指针"
            : "Mac 鼠标已呼出；\(deviceCursorHint)"
        status = "\(location) · 左键点击 / 拖动 · \(FPSKey.title(profile.cursorToggleKey)) 恢复转向"
    }
    func pointerDown(_ point: FPSPoint) {
        guard captured, cursorMode else { return }
        link?.pointerDown(point)
    }
    func pointerMoved(_ point: FPSPoint, age: TimeInterval) {
        guard captured, cursorMode else { return }
        link?.pointerMoved(point, age: age)
    }
    func pointerHoverOutside() {
        guard captured, cursorMode else { return }
        link?.pointerHoverOutside()
    }
    func pointerUp() {
        guard captured, cursorMode else { return }
        link?.pointerUp()
    }
    func mouse(dx: Double, dy: Double, age: TimeInterval) {
        guard captured, !cursorMode else { return }
        link?.mouse(dx: dx, dy: dy, age: age)
    }
    func scroll(_ amount: Double) {
        let now = ProcessInfo.processInfo.systemUptime
        guard captured, !cursorMode, profile.wheelSwitchWeapons, abs(amount) > 0.01, now - lastScroll >= 0.15 else { return }
        lastScroll = now; link?.pulse(amount > 0 ? .weapon1 : .weapon2)
    }

    func viewport(width: Int, height: Int) {
        guard width > 0, height > 0 else { return }
        let next = Double(width) / Double(height)
        guard viewportAspect != next else { return }
        if captured, (aspect > 1) != (next > 1) {
            releaseCapture(); status = "iPad 屏幕方向已变化，已释放输入。请重新捕获鼠标。"
        }
        viewportAspect = next
        if captured { link?.setAspect(next) }
    }
    func viewportRect(_ rect: FPSViewport) {
        guard rect.isValid else { return }
        if renderedViewport != nil, renderedViewport != rect, cursorMode { pointerUp() }
        renderedViewport = rect
    }

    func beginCalibration(_ target: String) {
        guard videoReady, !isEditingLayout else { return }
        setDirectView(false); releaseCapture(); enabled = true; calibration = target; showSettings = false
        status = "在游戏画面中点击\(calibrationTitle)进行标定。"; visualsChanged?()
    }
    func cancelCalibration() { calibration = nil; visualsChanged?(); synchronize() }
    func calibrate(x: Double, y: Double) {
        guard let target = calibration, !captured else { return }
        profile.setPoint(FPSPoint(x: x, y: y), target: target)
        calibration = nil; status = "位置已标定，可继续设置其他按键。"; visualsChanged?()
    }
    func selectProfile(_ id: UUID) {
        guard !isEditingLayout, id != profile.id, let selected = library.profiles.first(where: { $0.id == id }) else { return }
        releaseCapture(); editingSelection = true; profile = selected; editingSelection = false
        if let device { library.selectionByDevice[device.udid] = id }
        persist(); visualsChanged?()
    }
    func duplicateProfile() {
        guard library.profiles.count < 32 else { return }
        var copy = profile; copy.id = UUID(); copy.name = "\(profile.name) 副本"
        if copy.name.count > 80 { copy.name = "自定义 FPS" }
        library.profiles.append(copy); selectProfile(copy.id)
    }
    func resetProfile() {
        var reset = FPSProfile(); reset.id = profile.id; reset.name = profile.name; profile = reset
    }

    func viewerJSON() throws -> String {
        try (layoutEditor?.draft ?? profile).viewerJSON(calibrating: calibration, editing: isEditingLayout && !layoutTesting,
            selection: layoutEditor?.selection, session: layoutSession, sequence: layoutSequence)
    }
    func beginLayoutEditing(_ target: String = "joystick") {
        guard videoReady else { return }
        setDirectView(false); releaseCapture(); calibration = nil; enabled = true; showSettings = false
        if layoutEditor == nil {
            layoutSession = UUID().uuidString; layoutSequence = 0
            layoutDeviceUDID = device?.udid
            layoutEditor = FPSLayoutEditor(profile: profile, selection: target)
        } else { selectLayoutTarget(target) }
        layoutError = nil; status = "拖动按键移动位置，拖动角点调整大小。"
        layoutTestMessage = nil
    }
    func selectLayoutTarget(_ target: String) {
        guard !layoutSaving else { return }
        stopLayoutTest()
        guard var editor = layoutEditor else { return }
        editor.endInteraction(); editor.select(target); layoutEditor = editor
    }
    func beginLayoutInteraction() {
        guard !layoutSaving else { return }
        stopLayoutTest()
        guard var editor = layoutEditor else { return }
        editor.beginInteraction(); layoutEditor = editor
    }
    func endLayoutInteraction() {
        guard var editor = layoutEditor else { return }
        editor.endInteraction(); layoutEditor = editor
    }
    func editLayout(_ update: (inout FPSProfile) -> Void) {
        guard !layoutSaving else { return }
        stopLayoutTest()
        guard var editor = layoutEditor else { return }
        do { try editor.edit(update); layoutError = nil; layoutEditor = editor }
        catch { layoutError = error.localizedDescription }
    }
    func layoutGeometry(target: String, point: FPSPoint? = nil, radius: Double? = nil,
                        width: Double? = nil, height: Double? = nil, size: Double? = nil) {
        guard !layoutSaving else { return }
        stopLayoutTest()
        guard var editor = layoutEditor else { return }
        do {
            try editor.geometry(target: target, point: point, radius: radius, width: width, height: height, size: size, aspect: aspect)
            layoutError = nil; layoutEditor = editor
        } catch { layoutError = error.localizedDescription }
    }
    func undoLayout() {
        guard !layoutSaving else { return }
        stopLayoutTest()
        guard var editor = layoutEditor else { return }
        editor.undo(); layoutError = nil; layoutEditor = editor
    }
    func redoLayout() {
        guard !layoutSaving else { return }
        stopLayoutTest()
        guard var editor = layoutEditor else { return }
        editor.redo(); layoutError = nil; layoutEditor = editor
    }
    func resetLayout() {
        guard !layoutSaving else { return }
        stopLayoutTest()
        guard var editor = layoutEditor else { return }
        do { try editor.reset(); layoutError = nil; layoutEditor = editor }
        catch { layoutError = error.localizedDescription }
    }
    func addLayoutButton() {
        addLayoutButton(swipe: false)
    }
    func addLayoutSwipe() { addLayoutButton(swipe: true) }
    private func addLayoutButton(swipe: Bool) {
        guard !layoutSaving else { return }
        stopLayoutTest()
        guard var editor = layoutEditor else { return }
        do {
            try editor.addCustomButton(swipe: swipe); layoutError = nil; layoutEditor = editor
            layoutTestMessage = swipe ? "已添加滑动按钮，拖动起点和终点，再设置时长和按键。" : "已添加按钮，修改名称和按键后，把圆圈拖到游戏按钮中心。"
        } catch { layoutError = error.localizedDescription }
    }
    func removeLayoutButton() {
        guard !layoutSaving else { return }
        stopLayoutTest()
        guard var editor = layoutEditor else { return }
        do {
            try editor.removeMapping(editor.selection); layoutError = nil; layoutEditor = editor
            layoutTestMessage = "已删除映射；可以撤销，保存后生效。"
        } catch { layoutError = error.localizedDescription }
    }
    func addLayoutMapping(_ target: String) {
        guard !layoutSaving, var editor = layoutEditor else { return }
        stopLayoutTest()
        do { try editor.addMapping(target); layoutError = nil; layoutEditor = editor }
        catch { layoutError = error.localizedDescription }
    }
    @discardableResult func saveLayout() -> Bool {
        guard !layoutSaving else { return false }
        stopLayoutTest()
        guard let editor = layoutEditor else { return false }
        do {
            try editor.draft.validate()
            var saved = library
            guard let index = saved.profiles.firstIndex(where: { $0.id == editor.draft.id }) else { return false }
            saved.profiles[index] = editor.draft
            if let udid = device?.udid ?? layoutDeviceUDID { saved.selectionByDevice[udid] = editor.draft.id }
            let snapshot = saved, draft = editor.draft, url = libraryURL, session = layoutSession
            layoutSaving = true; layoutError = nil; status = "正在保存布局…"
            Task {
                // External volumes can stall an atomic file open. Keep this
                // write off the main thread so the window remains responsive.
                let result = await Task.detached(priority: .userInitiated) {
                    Result { try snapshot.save(to: url) }
                }.value
                layoutSaving = false
                switch result {
                case .success:
                    library = snapshot
                    guard layoutSession == session else { return }
                    editingSelection = true; profile = draft; editingSelection = false
                    layoutError = nil; layoutSession = ""; layoutDeviceUDID = nil; layoutEditor = nil
                    status = "布局已保存；点击画面或按 F8 开始游戏。"
                case .failure(let error):
                    layoutError = "布局保存失败：\(error.localizedDescription)"
                }
            }
            return true
        } catch { layoutError = "布局保存失败：\(error.localizedDescription)"; return false }
    }
    func cancelLayoutEditing() {
        guard isEditingLayout else { return }
        stopLayoutTest()
        layoutError = nil; layoutSession = ""; layoutDeviceUDID = nil; layoutEditor = nil
        if ready { status = "已取消布局修改；点击画面或按 F8 继续。" }
    }
    func layoutEvent(_ event: [String: Any]) {
        guard enabled, !captured, !layoutSaving, var editor = layoutEditor,
              event["session"] as? String == layoutSession,
              let sequence = event["sequence"] as? Int, sequence > layoutSequence else { return }
        layoutSequence = sequence
        if let command = event["command"] as? String {
            switch command {
            case "undo": undoLayout()
            case "redo": redoLayout()
            case "save": saveLayout()
            case "cancel": cancelLayoutEditing()
            default: visualsChanged?()
            }
            return
        }
        guard videoReady, let target = event["target"] as? String, let phase = event["phase"] as? String,
              ["begin", "change", "end", "cancel", "select"].contains(phase) else { visualsChanged?(); return }
        editor.select(target)
        if phase == "select" { editor.endInteraction(); layoutEditor = editor; return }
        if phase == "begin" { stopLayoutTest(); editor.beginInteraction() }
        if phase == "cancel" { editor.endInteraction(cancelled: true); layoutEditor = editor; return }
        let point: FPSPoint?
        if let x = event["x"] as? Double, let y = event["y"] as? Double { point = FPSPoint(x: x, y: y) }
        else { point = nil }
        do {
            try editor.geometry(target: target, point: point, radius: event["radius"] as? Double,
                width: event["width"] as? Double, height: event["height"] as? Double,
                size: event["size"] as? Double,
                end: (event["endX"] as? Double).flatMap { x in (event["endY"] as? Double).map { FPSPoint(x: x, y: $0) } }, aspect: aspect)
            layoutError = nil
        } catch { layoutError = error.localizedDescription }
        if phase == "end" { editor.endInteraction() }
        layoutEditor = editor
    }

    func testLayoutAction() {
        guard let editor = layoutEditor, let button = editor.draft.buttons.first(where: { $0.id == editor.selection }) else { return }
        do { runLayoutTest(try FPSInputPreview.button(button.id, profile: editor.draft), title: button.title) }
        catch { layoutError = error.localizedDescription }
    }
    func testLayoutLook(horizontal: Bool) {
        guard let editor = layoutEditor else { return }
        do {
            runLayoutTest(try FPSInputPreview.look(horizontal: horizontal, profile: editor.draft, aspect: aspect),
                          title: horizontal ? "鼠标向右" : "鼠标向下")
        } catch { layoutError = error.localizedDescription }
    }
    func testLayoutMovement() {
        guard let editor = layoutEditor else { return }
        do {
            runLayoutTest(try FPSInputPreview.movement(profile: editor.draft, aspect: aspect), title: "WASD 八向换向")
        } catch { layoutError = error.localizedDescription }
    }
    func testLayoutForward() {
        guard let editor = layoutEditor else { return }
        do {
            runLayoutTest(try FPSInputPreview.forward(profile: editor.draft, aspect: aspect), title: "W 直行（无鼠标转向）")
        } catch { layoutError = error.localizedDescription }
    }
    func testLayoutDiagonalWithLook() {
        guard let editor = layoutEditor else { return }
        do {
            runLayoutTest(try FPSInputPreview.diagonalWithLook(profile: editor.draft, aspect: aspect),
                          title: "W+A 加鼠标转向")
        } catch { layoutError = error.localizedDescription }
    }
    private func runLayoutTest(_ frames: [FPSState], title: String) {
        guard isEditingLayout, !captured, !layoutSaving, videoReady, ready, let currentLink = link else {
            layoutError = "连接 iPad 画面和 FPS 输入通道后才能测试"; return
        }
        stopLayoutTest()
        layoutError = nil; layoutTesting = true; layoutTestMessage = "正在测试：\(title)"
        visualsChanged?()
        let testEpoch = UUID(); layoutTestEpoch = testEpoch
        layoutTestTask = Task { [weak self] in
            do {
                for frame in frames {
                    try Task.checkCancellation()
                    guard self?.layoutTestEpoch == testEpoch else { return }
                    currentLink.send(frame)
                    try await Task.sleep(nanoseconds: UInt64(FPSInputPreview.interval * 1_000_000_000))
                }
            } catch { return }
            guard let self, layoutTestEpoch == testEpoch else { return }
            currentLink.releaseAll(); layoutTesting = false; layoutTestTask = nil
            visualsChanged?()
            layoutTestMessage = "\(title)测试已发送，请观察 iPad 的实际响应。"
        }
    }
    private func stopLayoutTest() {
        guard layoutTestTask != nil else { return }
        layoutTestEpoch = UUID(); layoutTestTask?.cancel(); layoutTestTask = nil
        layoutTesting = false; link?.releaseAll()
        visualsChanged?()
    }
    private func profileChanged() {
        releaseCapture()
        guard !editingSelection else { return }
        do {
            try profile.validate()
            if let index = library.profiles.firstIndex(where: { $0.id == profile.id }) { library.profiles[index] = profile }
            persist(); visualsChanged?()
        } catch { status = error.localizedDescription }
    }
    private func persist() {
        do { try library.save(to: libraryURL) } catch { status = "FPS 配置保存失败：\(error.localizedDescription)" }
    }
    private func stopLink() {
        edgeCursorPoint = nil
        setDirectView(false)
        stopLayoutTest()
        releaseCapture(); link?.stop(); link = nil; ready = false; connecting = false
        deviceCursorAvailable = false; deviceCursorVisible = false; supportsDeviceCursor = false
        roundTripMilliseconds = nil; remoteContacts = 0; hasRemoteOrientation = false; epoch = UUID()
    }
    func shutdown() { enabled = false; stopLink() }
}
