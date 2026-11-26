import Foundation
import SwiftUI
import AppKit
import IControlCore

enum ControlPhase: Equatable {
    case idle, waitingUSB, waitingServer, checking, connecting, passwordRequired, connected, problem
    var title: String {
        switch self {
        case .idle: return "准备连接"
        case .waitingUSB: return "等待 USB 数据连接"
        case .waitingServer: return "等待 iPad 控制端"
        case .checking: return "正在检查控制端"
        case .connecting: return "正在连接画面"
        case .passwordRequired: return "需要控制密码"
        case .connected: return "画面已连接"
        case .problem: return "连接需要处理"
        }
    }
    var color: Color {
        switch self {
        case .connected: return .green
        case .checking, .connecting: return .blue
        case .waitingUSB, .waitingServer, .passwordRequired: return .orange
        case .problem: return .red
        case .idle: return .secondary
        }
    }
}

struct LogEntry: Identifiable {
    let id = UUID()
    let time = Date()
    let message: String
}

private struct DeviceScan: Sendable {
    let devices: [USBDevice]
    let hardwarePresent: Bool
    let error: String?
}

@MainActor
final class ControlModel: ObservableObject {
    @Published var devices: [USBDevice] = []
    @Published private(set) var selectedUDID = ""
    @Published var hardwarePresent = false
    @Published var discoveryError: String?
    @Published var scanning = false
    @Published var phase: ControlPhase = .idle
    @Published var detail = "用 USB 数据线连接 iPad，然后点“连接 iPad”。"
    @Published var wantsConnection = false
    @Published var viewerConnected = false
    @Published var viewerURL: URL?
    @Published var connectionAttempt = 0
    @Published var vncPassword = ""
    @Published var rememberPassword = true
    @Published var logs: [LogEntry] = []
    @Published var showLogs = false
    @Published var showInstaller = false
    @Published var showPasswordPrompt = false
    @Published var showTextSender = false
    @Published var autoReconnect = UserDefaults.standard.object(forKey: "autoReconnect") as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoReconnect, forKey: "autoReconnect") }
    }
    let viewerDriver = ViewerDriver()
    let fpsController: FPSController
    let mux: USBMux
    let isDemo: Bool
    let fpsUpdaterOnly = CommandLine.arguments.contains("--update-fps") || Bundle.main.object(forInfoDictionaryKey: "IControlFPSUpdaterOnly") as? Bool == true
    private var monitor: Task<Void, Never>?
    private var attemptTask: Task<Void, Never>?
    private var forwarder: USBForwarder?
    private var viewerServer: LocalViewerServer?
    private var deviceCache: [String: USBDevice] = [:]
    private var attemptRunning = false
    private var lastAttempt: TimeInterval = 0
    private var epoch = UUID()
    private var passwordPending = false
    private var authenticationWaiting = false
    private var passwordLoadAttempted = false
    private var started = false
    private var lastDiscoveryMessage = ""

    init() {
        let testSocket = Bundle.main.object(forInfoDictionaryKey: "IControlDemoSocket") as? String
        isDemo = testSocket != nil
        mux = USBMux(socketPath: testSocket ?? "/var/run/usbmuxd")
        let initialUDID = UserDefaults.standard.string(forKey: "lastDevice") ?? ""
        selectedUDID = initialUDID
        fpsController = FPSController(mux: mux, isDemo: isDemo, selectedDevice: initialUDID)
        viewerDriver.fpsController = fpsController
        fpsController.log = { [weak self] message in self?.log(message) }
    }

    var selectedDevice: USBDevice? { devices.first { $0.udid == selectedUDID } }
    var localPort: UInt16? { forwarder?.localPort }
    var usbTitle: String {
        if selectedDevice != nil { return "USB 数据连接已就绪" }
        if hardwarePresent { return "检测到 iPad，数据连接未就绪" }
        return "等待连接 iPad"
    }
    var usbAdvice: String {
        if selectedDevice != nil { return "\(selectedDevice!.productType) · iPadOS \(selectedDevice!.version)" }
        if hardwarePresent { return "解锁 iPad 并信任这台 Mac。若仍未就绪，重新插入数据线。" }
        return "请连接支持数据传输的 USB 线，保持 iPad 解锁。"
    }

    func start() {
        guard !started else { return }
        started = true
        log(isDemo ? "当前窗口连接模拟设备，仅用于界面测试。" : "iControl 已启动，正在检测 USB 设备。")
        monitor = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    func select(_ udid: String) {
        guard selectedUDID != udid else { return }
        if wantsConnection { stopConnection() }
        selectedUDID = udid
        if fpsUpdaterOnly { return }
        if !isDemo { UserDefaults.standard.set(udid, forKey: "lastDevice") }
        vncPassword = ""
        passwordLoadAttempted = false
        loadPasswordOnce()
        fpsController.update(device: selectedDevice, videoReady: false)
    }

    func refresh() async {
        guard !scanning else { return }
        scanning = true
        let mux = self.mux, cache = deviceCache, demo = isDemo
        let scan = await Task.detached(priority: .utility) { () -> DeviceScan in
            let physical = demo || USBHardware.iPadPresent()
            do {
                let items = try mux.devices().map { device in
                    let key = "\(device.udid):\(device.deviceID)"
                    return cache[key] ?? ((try? mux.details(for: device)) ?? device)
                }.filter { $0.productType.isEmpty || $0.isIPad }
                return DeviceScan(devices: items, hardwarePresent: physical, error: nil)
            } catch { return DeviceScan(devices: [], hardwarePresent: physical, error: error.localizedDescription) }
        }.value
        scanning = false
        guard !Task.isCancelled else { return }
        devices = scan.devices; hardwarePresent = scan.hardwarePresent; discoveryError = scan.error
        for device in devices where !device.productType.isEmpty { deviceCache["\(device.udid):\(device.deviceID)"] = device }
        if deviceCache.count > 32 { deviceCache = [:] }
        if selectedDevice == nil && !wantsConnection, let first = devices.first { select(first.udid) }
        if fpsUpdaterOnly { return }
        if selectedDevice != nil { loadPasswordOnce() }
        fpsController.update(device: selectedDevice, videoReady: viewerConnected)
        let discovery = scan.error ?? usbTitle
        if discovery != lastDiscoveryMessage { lastDiscoveryMessage = discovery; log(discovery) }
        guard wantsConnection else { return }
        if selectedUDID.isEmpty, let first = devices.first {
            selectedUDID = first.udid
            if !isDemo { UserDefaults.standard.set(first.udid, forKey: "lastDevice") }
        }
        guard let device = selectedDevice else {
            if viewerURL != nil { tearDownTransport(); log("USB 数据连接已断开。") }
            phase = .waitingUSB; detail = usbAdvice
            if !autoReconnect { stopConnection() }
            return
        }
        if let forwarder, forwarder.device.deviceID != device.deviceID || !forwarder.snapshot().running {
            tearDownTransport(); log("USB 设备已重新接入，正在恢复连接。")
        }
        if viewerConnected { phase = .connected; return }
        if passwordPending { phase = .passwordRequired; return }
        let elapsed = ProcessInfo.processInfo.systemUptime - lastAttempt
        if phase == .connecting && elapsed < 15 { return }
        if !attemptRunning && elapsed >= 5 { attemptConnection(to: device) }
    }

    func connect() {
        guard !wantsConnection else { return }
        wantsConnection = true; passwordPending = false; lastAttempt = 0
        epoch = UUID()
        if let device = selectedDevice { attemptConnection(to: device) }
        else { phase = .waitingUSB; detail = usbAdvice; log("开始等待 iPad 的 USB 数据连接。") }
    }

    private func attemptConnection(to device: USBDevice) {
        guard wantsConnection, !attemptRunning else { return }
        attemptRunning = true; lastAttempt = ProcessInfo.processInfo.systemUptime
        phase = .checking; detail = "正在检查 iPad 上的控制服务。"
        let thisEpoch = epoch, mux = self.mux
        attemptTask = Task { [weak self] in
            let greeting = await Task.detached(priority: .userInitiated) { () -> Result<String, Error> in
                Result { try mux.vncGreeting(device: device) }
            }.value
            guard let self else { return }
            guard self.epoch == thisEpoch, self.wantsConnection else { return }
            self.attemptRunning = false
            switch greeting {
            case .failure(let error):
                self.phase = .waitingServer
                self.detail = "控制端尚未响应。首次使用请点“安装 / 配置控制端”。\n\(error.localizedDescription)"
            case .success:
                do {
                    if self.forwarder == nil {
                        let forwarding = try USBForwarder(mux: mux, device: device)
                        do {
                            self.viewerServer = try LocalViewerServer(resources: AppResources.root.appendingPathComponent("Viewer"), targetPort: forwarding.localPort)
                        } catch { forwarding.stop(); throw error }
                        self.forwarder = forwarding
                        self.viewerURL = self.viewerServer!.url
                        self.log("USB 控制通道已开启。")
                    }
                    self.connectionAttempt += 1
                    self.phase = .connecting
                    self.detail = "控制端已响应，正在验证密码并打开画面。"
                } catch {
                    self.phase = .problem; self.detail = error.localizedDescription; self.log(error.localizedDescription)
                }
            }
        }
    }

    func submitPassword() {
        guard !vncPassword.isEmpty else { return }
        showPasswordPrompt = false
        if passwordPending && authenticationWaiting && viewerURL != nil {
            passwordPending = false; phase = .connecting; lastAttempt = ProcessInfo.processInfo.systemUptime
            viewerDriver.credentials(vncPassword)
        } else if passwordPending && viewerURL != nil {
            passwordPending = false; authenticationWaiting = false; phase = .connecting
            lastAttempt = ProcessInfo.processInfo.systemUptime; connectionAttempt += 1
        } else if wantsConnection {
            passwordPending = false; lastAttempt = 0
            if let device = selectedDevice { attemptConnection(to: device) }
        } else { connect() }
    }

    func presentPasswordPromptIfNeeded() {
        guard phase == .passwordRequired, !showInstaller, !showTextSender, !fpsController.showSettings else { return }
        showPasswordPrompt = true
    }

    func viewerEvent(_ event: [String: Any], source: URL?) {
        guard source == viewerURL, wantsConnection else { return }
        switch event["type"] as? String {
        case "fpsLayoutEdit", "fpsLayoutCommand":
            fpsController.layoutEvent(event)
            return
        case "connected":
            viewerConnected = true; passwordPending = false; authenticationWaiting = false; showPasswordPrompt = false; phase = .connected
            detail = "点击画面即可触摸、拖动和输入；滚轮用于滑动。"
            log("控制画面已建立连接。")
            if rememberPassword && !vncPassword.isEmpty && !isDemo {
                do { try PasswordStore.save(vncPassword, device: selectedUDID) } catch { log(error.localizedDescription) }
            }
        case "credentialsRequired":
            passwordPending = true; authenticationWaiting = true; phase = .passwordRequired; detail = "请输入这台 iPad 的控制密码，再点“连接”。"
            presentPasswordPromptIfNeeded()
        case "securityFailure":
            viewerConnected = false; passwordPending = true; authenticationWaiting = false; phase = .passwordRequired
            detail = "控制密码验证失败，请重新输入。"; log(detail)
            vncPassword = ""; presentPasswordPromptIfNeeded()
        case "disconnected":
            viewerConnected = false; authenticationWaiting = false
            if !passwordPending {
                phase = .waitingServer; detail = autoReconnect ? "连接已中断，正在通过 USB 自动重连。" : "连接已中断。请重新点击“连接 iPad”。"
                log(detail)
                if !autoReconnect { stopConnection() }
            }
        case "error":
            viewerConnected = false; showPasswordPrompt = false; phase = .problem
            detail = "内置画面启动失败，可使用下方的“系统屏幕共享”备用入口。"
            log(detail)
        case "fpsViewport":
            if let width = event["width"] as? Int, let height = event["height"] as? Int {
                fpsController.viewport(width: width, height: height)
            }
        case "fpsViewportRect":
            if let x = event["x"] as? Double, let y = event["y"] as? Double,
               let width = event["width"] as? Double, let height = event["height"] as? Double {
                fpsController.viewportRect(.init(x: x, y: y, width: width, height: height))
            }
        case "fpsCalibrationPoint":
            if let x = event["x"] as? Double, let y = event["y"] as? Double { fpsController.calibrate(x: x, y: y) }
        default: break
        }
        fpsController.update(device: selectedDevice, videoReady: viewerConnected)
    }

    func stopConnection() {
        wantsConnection = false; passwordPending = false; epoch = UUID()
        tearDownTransport(); phase = .idle
        detail = "连接已停止。点击“连接 iPad”可重新连接。"
        log("已停止本应用的 USB 控制连接。")
    }

    private func tearDownTransport() {
        showPasswordPrompt = false; authenticationWaiting = false
        fpsController.update(device: selectedDevice, videoReady: false)
        viewerDriver.disconnect()
        viewerServer?.stop(); viewerServer = nil
        forwarder?.stop(); forwarder = nil
        viewerURL = nil; viewerConnected = false; attemptRunning = false
        epoch = UUID()
    }

    func openScreenSharing() {
        guard let port = forwarder?.localPort, let url = URL(string: "vnc://127.0.0.1:\(port)") else { return }
        NSWorkspace.shared.open(url)
    }

    func installed(password: String, device: USBDevice, responding: Bool, fpsToken: String? = nil, fpsResponding: Bool = false) {
        stopConnection(); selectedUDID = device.udid; vncPassword = password
        if !isDemo && rememberPassword {
            do { try PasswordStore.save(password, device: device.udid) } catch { log(error.localizedDescription) }
        }
        if let fpsToken {
            fpsController.rememberToken(fpsToken, device: device, remember: rememberPassword)
            log(fpsResponding ? "FPS 控制端已通过 USB 身份验证。" : "FPS 控制端已配置，连接画面后会继续检查输入通道。")
        }
        log(responding ? "iPad 控制端已配置，USB 服务验证通过。" : "iPad 控制端已配置，正在等待服务响应。")
        connect()
    }

    func makeInstaller() -> USBInstaller {
        USBInstaller(mux: mux, helper: Bundle.main.executableURL!, packages: AppResources.root.appendingPathComponent("ServerPackages"), supportDirectory: AppResources.support)
    }

    func log(_ message: String) {
        if logs.last?.message == message { return }
        logs.append(LogEntry(message: message)); if logs.count > 300 { logs.removeFirst(logs.count - 300) }
    }

    private func loadPasswordOnce() {
        guard !isDemo, !selectedUDID.isEmpty, !passwordLoadAttempted else { return }
        passwordLoadAttempted = true
        guard vncPassword.isEmpty else { return }
        let udid = selectedUDID
        // A newly signed build may require the user's Keychain authorization.
        // Keep the window responsive while macOS waits for that decision.
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                Result { try PasswordStore.load(device: udid) }
            }.value
            guard let self, self.selectedUDID == udid, self.vncPassword.isEmpty else { return }
            switch result {
            case .success(let password): self.vncPassword = password ?? ""
            case .failure(let error): self.log(error.localizedDescription)
            }
        }
    }

    func diagnostics() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        var result = "iControl \(AppResources.version)\nmacOS \(ProcessInfo.processInfo.operatingSystemVersionString)\n"
        result += "物理 iPad：\(hardwarePresent ? "已发现" : "未发现")\nUSB 数据设备：\(devices.count)\n状态：\(phase.title)\n"
        if let device = selectedDevice { result += "设备：\(device.name)，\(device.productType)，iPadOS \(device.version)\n" }
        result += "\n" + logs.map { "[\(formatter.string(from: $0.time))] \($0.message)" }.joined(separator: "\n")
        return result
    }

    func copyDiagnostics() {
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(diagnostics(), forType: .string)
    }
    func shutdown() {
        monitor?.cancel(); attemptTask?.cancel(); fpsController.shutdown(); wantsConnection = false; tearDownTransport()
    }
}
