import AVFoundation
import Foundation
import IControlCore

/// Except for the cancellation flag, all mutable state and AV objects belong to `queue`.
/// Successive monitors share it: the old graph is released before a new input opens.
final class IPadAudioMonitor: @unchecked Sendable {
    private static let queue = DispatchQueue(label: "com.icontrol.ipad-audio", qos: .userInitiated)
    private let lock = NSLock()
    private var cancelled = false
    private var isCancelled: Bool { lock.withLock { cancelled } }
    private let target: USBDevice
    private let peers: [USBDevice]
    private let report: @Sendable (IPadAudioState) -> Void
    private let preferredID: String?
    private let reservedIDs: Set<String>
    private var resolvedID: String?
    private var discovery: AVCaptureDevice.DiscoverySession?
    private var timer: DispatchSourceTimer?
    private var session: AVCaptureSession?
    private var preview: AVCaptureAudioPreviewOutput?
    private var observers: [NSObjectProtocol] = []
    private var graphID: UUID?
    private var failure: String?
    private var lastSignal: TimeInterval?
    private var previous: IPadAudioState?

    init(target: USBDevice, peers: [USBDevice], preferredID: String?, reservedIDs: Set<String>, report: @escaping @Sendable (IPadAudioState) -> Void) {
        self.target = target; self.peers = peers; self.preferredID = preferredID; self.reservedIDs = reservedIDs; self.report = report
    }

    func start() {
        Self.queue.async { [self] in
            guard !isCancelled else { return }
            // On macOS the .microphone category includes HAL digital audio inputs. It
            // is a discovery filter, NOT permission to use the default microphone.
            discovery = .init(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified)
            let timer = DispatchSource.makeTimerSource(queue: Self.queue)
            self.timer = timer
            timer.schedule(deadline: .now(), repeating: .milliseconds(750), leeway: .milliseconds(100))
            timer.setEventHandler { [weak self] in self?.poll() }
            timer.resume()
        }
    }

    func cancel() {
        lock.withLock { cancelled = true }
        Self.queue.async { [self] in dispose() }
    }

    private func dispose() {
        timer?.cancel(); timer = nil
        closeGraph(); discovery = nil
    }

    private func publish(_ state: IPadAudioState) {
        guard !isCancelled, state != previous else { return }
        previous = state
        report(state)
    }

    private func poll() {
        guard !isCancelled, let discovery else { return }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            dispose()
            publish(.init(message: "音频输入权限不可用。请检查“隐私与安全性 → 麦克风”后重试。", action: .privacy))
            return
        }
        let devices = discovery.devices
        let candidates = devices.compactMap { IPadAudioSource($0, target: target, peers: peers) }.sorted {
            $0.name == $1.name ? $0.id < $1.id : $0.name < $1.name
        }
        // An exact serial outranks even an older manual association. Re-resolve
        // every poll because HAL may publish or replace endpoints after USB login.
        let identified = candidates.filter { $0.match == .serial }
        let sources = identified.isEmpty ? candidates : identified
        let selection = IPadAudioSource.resolve(sources, preferredID: preferredID, reservedIDs: reservedIDs)
        if resolvedID != selection?.id {
            closeGraph(); failure = nil; resolvedID = selection?.id
        }
        guard let source = selection, let device = devices.first(where: { $0.uniqueID == source.id }) else {
            let message = sources.isEmpty ? "等待 \(target.name) 的 USB 音频输入；启用后会自动连接。"
                : "无法自动确认 \(target.name) 的输入。请选择一次，下次连接这台 iPad 时将自动使用。"
            publish(.init(message: message, action: sources.isEmpty ? .setup : .none, sources: sources))
            return
        }
        if session == nil && failure == nil {
            do { try openGraph(device: device) }
            catch { closeGraph(); failure = error.localizedDescription }
        }
        if let failure {
            publish(.init(message: failure, action: .retry, sources: sources, sourceID: source.id)); return
        }
        guard !isCancelled else { return }
        guard session?.isRunning == true, let route = preview?.connection(with: .audio) else {
            closeGraph()
            let message = "音频会话已停止。检查 Mac 声音输出后重试。"
            failure = message
            publish(.init(message: message, action: .retry, sources: sources, sourceID: source.id)); return
        }
        let levels = route.audioChannels.filter(\.isEnabled).map(\.averagePowerLevel).filter(\.isFinite)
        let now = ProcessInfo.processInfo.systemUptime
        if route.isActive, let level = levels.max(), level > -65 { lastSignal = now }
        let recent = route.isActive && lastSignal.map { now - $0 < 2 } == true
        let message: String
        if recent { message = "检测到 iPad 输入电平，正送往 Mac 默认输出。" }
        else if !route.isActive || levels.isEmpty { message = "已打开输入，暂未取得电平；请在 iPad 上播放游戏声音。" }
        else { message = "监听中，未检测到明显电平。请播放游戏并检查游戏静音、iPad 音频路由。" }
        publish(.init(message: message, sources: sources, sourceID: source.id))
    }

    private func openGraph(device: AVCaptureDevice) throws {
        guard !isCancelled, device.isConnected else { throw ControlError("iPad 音频输入已断开。") }
        let session = AVCaptureSession()
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { throw ControlError("无法打开所选 iPad 输入。请停用再启用该输入后重试。") }
        session.addInput(input)
        let preview = AVCaptureAudioPreviewOutput()
        preview.outputDeviceUniqueID = nil  // nil is the Mac's default OUTPUT, never its input.
        preview.volume = 0
        guard session.canAddOutput(preview) else { throw ControlError("无法打开音频监听。请检查 Mac 的声音输出。") }
        session.addOutput(preview)
        guard preview.connection(with: .audio) != nil else { throw ControlError("所选设备没有可监听的音频通道。") }
        self.session = session; self.preview = preview
        let id = UUID()
        graphID = id
        observe(AVCaptureSession.runtimeErrorNotification, on: session, id: id, message: "音频会话出错")
        observe(AVCaptureSession.wasInterruptedNotification, on: session, id: id, message: "音频监听被系统中断。请在设备空闲后重试。")
        observe(AVCaptureSession.didStopRunningNotification, on: session, id: id, message: "音频会话已意外停止。请检查 iPad 和 Mac 输出后重试。")
        observe(AVCaptureDevice.wasDisconnectedNotification, on: device, id: id, message: "iPad 音频输入已断开。")
        guard !isCancelled else { return }
        session.startRunning() // Synchronous; never on the UI thread.
        guard session.isRunning, device.isConnected else { throw ControlError("iPad 音频会话未能启动。请检查输入和 Mac 输出后重试。") }
        // Cancellation may have happened while startRunning was blocked. Never
        // unmute an obsolete graph after its cancellation has been acknowledged.
        lock.withLock { if !cancelled { preview.volume = 1 } }
    }

    private func observe(_ name: Notification.Name, on sender: AnyObject, id: UUID, message: String) {
        let token = NotificationCenter.default.addObserver(forName: name, object: sender, queue: nil) { [weak self] note in
            let detail = (note.userInfo?[AVCaptureSessionErrorKey] as? NSError)?.localizedDescription
            Self.queue.async { [weak self] in
                guard let self, !self.isCancelled, self.graphID == id else { return }
                self.closeGraph()
                self.failure = detail.map { "\(message)：\($0)" } ?? message
                self.poll() // Report once. Do not spin a broken/in-use device in a restart loop.
            }
        }
        observers.append(token)
    }

    private func closeGraph() {
        graphID = nil
        for token in observers { NotificationCenter.default.removeObserver(token) }
        observers.removeAll()
        preview?.volume = 0
        if let session, session.isRunning { session.stopRunning() }
        session = nil; preview = nil; lastSignal = nil
    }
}
