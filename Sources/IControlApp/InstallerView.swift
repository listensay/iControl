import SwiftUI
import IControlCore

@MainActor
final class InstallerModel: ObservableObject {
    @Published var username = "mobile" { didSet { environment = nil } }
    @Published var sshPassword = "" { didSet { environment = nil } }
    @Published var separateAdmin = false { didSet { environment = nil } }
    @Published var adminPassword = "" { didSet { environment = nil } }
    @Published var controlPassword: String
    @Published var savePassword = true
    @Published var scale = 0.65
    @Published var fps = 60
    @Published var installFPS = true
    @Published var environment: InstallationEnvironment?
    @Published var busy = false
    @Published var mutating = false
    @Published var step: InstallationStep?
    @Published var error: String?
    @Published var success: String?
    private var cancellation: CancellationToken?
    weak var control: ControlModel?
    let device: USBDevice?
    init(control: ControlModel, device: USBDevice?) {
        self.control = control; self.device = device
        let existing = control.vncPassword
        controlPassword = (try? ControlPassword.validate(existing)) != nil ? existing : ControlPassword.generate()
    }
    private func credentials() throws -> SSHCredentials {
        try SSHCredentials(username: username, password: sshPassword, administratorPassword: separateAdmin ? adminPassword : nil)
    }
    private func progress(_ step: InstallationStep) { self.step = step }

    func inspect() {
        guard !busy, let device, let control else { return }
        do {
            let credentials = try credentials(), installer = control.makeInstaller(), cancellation = CancellationToken()
            let report: @Sendable (InstallationStep) -> Void = { [self] step in Task { @MainActor in self.progress(step) } }
            self.cancellation = cancellation; busy = true; mutating = false; error = nil; success = nil
            Task {
                let result = await Task.detached(priority: .userInitiated) {
                    Result {
                        try installer.inspect(device: device, credentials: credentials, cancellation: cancellation, progress: report)
                    }
                }.value
                busy = false; step = nil; self.cancellation = nil
                switch result {
                case .success(let environment): self.environment = environment
                case .failure(let failure): self.error = failure.localizedDescription
                }
            }
        } catch { self.error = error.localizedDescription }
    }

    func install() {
        guard !busy, environment?.canInstall == true, let device, let control else { return }
        do {
            let credentials = try credentials(), installer = control.makeInstaller(), password = controlPassword
            try ControlPassword.validate(password)
            let scale = self.scale, fps = self.fps
            let fpsToken = installFPS ? try control.fpsController.tokenForInstallation ?? FPSAccessToken.generate() : nil
            let cancellation = CancellationToken()
            let report: @Sendable (InstallationStep) -> Void = { [self] step in Task { @MainActor in self.progress(step) } }
            self.cancellation = cancellation; busy = true; mutating = true; error = nil; success = nil
            control.stopConnection()
            Task {
                let result = await Task.detached(priority: .userInitiated) {
                    Result {
                        try installer.install(device: device, credentials: credentials, password: password, fpsToken: fpsToken, scale: scale, framesPerSecond: fps, cancellation: cancellation, progress: report)
                    }
                }.value
                busy = false; mutating = false; step = nil; self.cancellation = nil
                switch result {
                case .success(let installed):
                    control.rememberPassword = savePassword
                    control.installed(password: password, device: device, responding: installed.serviceResponding, fpsToken: fpsToken, fpsResponding: installed.fpsServiceResponding)
                    success = installed.serviceResponding ? "画面控制端已配置，USB 服务验证通过。" : "画面控制端已配置，主窗口会继续等待服务响应。"
                    if fpsToken != nil {
                        success! += installed.fpsServiceResponding ? "FPS 输入通道验证通过。关闭此窗口后进入游戏，开启 FPS 模式并标定键位。" : "FPS 输入端已配置，连接画面后会继续检查；需在游戏内验证触控和画面延迟。"
                    } else { success! += "关闭此窗口后即可连接 iPad。" }
                    environment = nil
                case .failure(let failure): error = failure.localizedDescription
                }
            }
        } catch { self.error = error.localizedDescription }
    }

    func restore() {
        guard !busy, environment?.managedByIControl == true, let device, let control else { return }
        do {
            let credentials = try credentials(), installer = control.makeInstaller()
            let report: @Sendable (InstallationStep) -> Void = { [self] step in Task { @MainActor in self.progress(step) } }
            busy = true; mutating = true; error = nil; success = nil; control.stopConnection()
            Task {
                let result = await Task.detached(priority: .userInitiated) {
                    Result { try installer.restore(device: device, credentials: credentials, progress: report) }
                }.value
                busy = false; mutating = false; step = nil
                switch result {
                case .success:
                    success = "已恢复安装前的 TrollVNC 配置和 FPS 输入端文件。TrollVNC 软件包仍保留在 iPad 上。"; environment = nil
                    control.vncPassword = ""
                    control.fpsController.forgetToken(device: device.udid)
                    if !control.isDemo { try? PasswordStore.remove(device: device.udid) }
                case .failure(let failure): error = failure.localizedDescription
                }
            }
        } catch { self.error = error.localizedDescription }
    }
    func cancelInspection() { if !mutating { cancellation?.cancel() } }
    func clearCredentials() { sshPassword = ""; adminPassword = "" }
    func resetTrust() {
        guard !busy, let device else { return }
        do { try SSHTrust.reset(device: device.udid, supportDirectory: AppResources.support); error = nil; success = "此 iPad 的 SSH 信任记录已重置。下次检测会记录经 USB 连接的设备当前主机密钥。" }
        catch { self.error = error.localizedDescription }
    }
}

struct InstallerView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var state: InstallerModel
    @State private var reveal = false
    init(model: ControlModel, device: USBDevice?) { _state = StateObject(wrappedValue: InstallerModel(control: model, device: device)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 13) {
                Image(systemName: "shippingbox").font(.system(size: 30)).foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 5) {
                    Text("安装 iPad 控制端").font(.title2.weight(.semibold))
                    Text(state.device?.name ?? "USB 数据连接尚未就绪").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
                Button("完成") { dismiss() }.disabled(state.busy).keyboardShortcut(.cancelAction)
            }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if state.device == nil {
                        message("请先取得 iPad 的 USB 数据连接：解锁 iPad、信任这台 Mac，并重新插入数据线。连接就绪后重新打开此页面。", color: .orange)
                    }
                    Text("在已越狱的 iPad 上先安装 OpenSSH 和 PreferenceLoader。保持设备解锁和 USB 连接，再输入 iPad 的登录信息。")
                        .font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(4)
                    Text("palera1n 通常使用 mobile 账户，密码为越狱引导时设置的密码；可在 palera1n 中修改 Sudo Password。")
                        .font(.system(size: 11)).foregroundStyle(.secondary).lineSpacing(3)
                    VStack(alignment: .leading, spacing: 12) {
                        Text("1  连接并检测越狱环境").font(.system(size: 14, weight: .semibold))
                        HStack(spacing: 18) {
                            field("SSH 账户") { TextField("root 或 mobile", text: $state.username).textFieldStyle(.roundedBorder) }.frame(width: 170)
                            field("SSH 登录密码") { SecureField("iPad 的 SSH 密码", text: $state.sshPassword).textFieldStyle(.roundedBorder) }
                        }
                        Toggle("管理员密码与 SSH 登录密码不同", isOn: $state.separateAdmin).toggleStyle(.checkbox).font(.system(size: 11))
                        if state.separateAdmin {
                            field("管理员密码（sudo）") { SecureField("管理员密码", text: $state.adminPassword).textFieldStyle(.roundedBorder) }
                        }
                        HStack {
                            Button("检测环境") { state.inspect() }
                                .disabled(state.device == nil || state.sshPassword.isEmpty || state.busy)
                            Text("账户需要 root 或 sudo 安装权限。SSH 密码仅在本次操作期间保存在内存中。")
                                .font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                    }.disabled(state.busy)
                    if let environment = state.environment {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Label("越狱环境已识别", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                                Spacer()
                                Text(environment.mode == .rootless ? "Rootless" : "Rootful").font(.system(size: 11, weight: .semibold))
                            }.font(.system(size: 12))
                            Grid(alignment: .leading, horizontalSpacing: 32, verticalSpacing: 8) {
                                GridRow { Text("系统版本"); Text(environment.firmware) }
                                GridRow { Text("安装包架构"); Text(environment.architecture) }
                                GridRow { Text("PreferenceLoader"); Text(environment.hasPreferenceLoader ? "已安装" : "需要安装") }
                                GridRow { Text("TrollVNC"); Text(environment.installedVersion.isEmpty ? "尚未安装" : environment.installedVersion) }
                            }.font(.system(size: 11)).foregroundStyle(.secondary)
                            ForEach(environment.requirements, id: \.self) { Text($0).font(.system(size: 11)).foregroundStyle(.orange) }
                        }.padding(15).background(Color.green.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        Text("2  设置控制密码与画质").font(.system(size: 14, weight: .semibold))
                        HStack(alignment: .bottom, spacing: 12) {
                            field("控制密码 · 8 位") {
                                Group {
                                    if reveal { TextField("8 位控制密码", text: $state.controlPassword) }
                                    else { SecureField("8 位控制密码", text: $state.controlPassword) }
                                }.textFieldStyle(.roundedBorder)
                            }
                            Button { reveal.toggle() } label: { Image(systemName: reveal ? "eye.slash" : "eye") }.help("显示 / 隐藏控制密码")
                            Button("重新生成") { state.controlPassword = ControlPassword.generate() }
                        }
                        Toggle("把控制凭据保存到 Mac 钥匙串", isOn: $state.savePassword).toggleStyle(.checkbox).font(.system(size: 11))
                        Toggle("安装 FPS 多点触摸控制端（含 iPad 游戏指针）", isOn: $state.installFPS).toggleStyle(.checkbox).font(.system(size: 11))
                        Text("FPS 模式支持同时移动、转向和开火。1.4.0 控制端增加显示在 iPad 游戏画面上的鼠标指针；连接后可查看指针是否就绪。")
                            .font(.system(size: 11)).foregroundStyle(.secondary).lineSpacing(3)
                        HStack(spacing: 22) {
                            Picker("分辨率", selection: $state.scale) {
                                Text("流畅 · 50%").tag(0.5); Text("平衡 · 65%").tag(0.65); Text("清晰 · 80%").tag(0.8); Text("原始 · 100%").tag(1.0)
                            }
                            Picker("帧率", selection: $state.fps) { Text("15 FPS").tag(15); Text("30 FPS").tag(30); Text("60 FPS").tag(60) }
                        }.font(.system(size: 11))
                        Text("控制端使用官方 TrollVNC \(ServerPackage.version)。安装前会校验安装包，按检测到的越狱模式选择版本，并备份原配置。")
                            .font(.system(size: 10)).foregroundStyle(.secondary).lineSpacing(3)
                    }.disabled(state.busy)
                    if state.busy {
                        HStack(spacing: 12) {
                            ProgressView().controlSize(.small)
                            Text(state.step?.rawValue ?? "正在准备…").font(.system(size: 12, weight: .medium))
                            Spacer()
                            if !state.mutating { Button("取消检查") { state.cancelInspection() } }
                        }.padding(14).background(Color.blue.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
                    }
                    if let error = state.error { message(error, color: .red) }
                    if state.error?.contains("主机密钥") == true {
                        Button("重置此 iPad 的 SSH 信任") { state.resetTrust() }.disabled(state.busy)
                    }
                    if let success = state.success { message(success, color: .green) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack {
                if state.environment?.managedByIControl == true {
                    Button("恢复原配置") { state.restore() }.disabled(state.busy)
                        .help("恢复本次 iControl 配置前的 TrollVNC 设置")
                }
                Spacer()
                Button(state.environment?.installedVersion.isEmpty == false ? "配置并连接" : "安装并连接") { state.install() }
                    .buttonStyle(PrimaryActionButtonStyle()).disabled(state.busy || state.environment?.canInstall != true)
            }
        }
        .padding(26).frame(width: 700, height: 700)
        .interactiveDismissDisabled(state.busy)
        .onDisappear { state.clearCredentials() }
    }
    private func field<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) { Text(title).font(.system(size: 11)).foregroundStyle(.secondary); content() }
    }
    private func message(_ text: String, color: Color) -> some View {
        Text(text).font(.system(size: 12)).foregroundStyle(color).lineSpacing(4)
            .frame(maxWidth: .infinity, alignment: .leading).padding(14).background(color.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
            .textSelection(.enabled)
    }
}
