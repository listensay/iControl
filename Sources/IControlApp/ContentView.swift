import SwiftUI
import AppKit
import IControlCore

struct ContentView: View {
    @ObservedObject var model: ControlModel
    @ObservedObject private var fps: FPSController

    init(model: ControlModel) {
        self.model = model
        _fps = ObservedObject(wrappedValue: model.fpsController)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 18) {
                sidebar.frame(width: 252)
                VStack(spacing: 14) {
                    viewerCard
                    if model.showLogs { logsPanel }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(24)
        .padding(.top, 12)
        .frame(minWidth: 940, minHeight: 660)
        .background(Color(nsColor: .windowBackgroundColor))
        .tint(.blue)
        .sheet(isPresented: $model.showInstaller) {
            InstallerView(model: model, device: model.selectedDevice)
        }
        .sheet(isPresented: $model.showPasswordPrompt) { ControlPasswordView(model: model) }
        .sheet(isPresented: $model.showTextSender) { TextSenderView(driver: model.viewerDriver) }
        .sheet(isPresented: $fps.showSettings) { FPSSettingsView(controller: fps) }
        .onChange(of: model.showInstaller) { _, shown in
            if shown { fps.releaseCapture() } else { model.presentPasswordPromptIfNeeded() }
        }
        .onChange(of: model.showTextSender) { _, shown in if !shown { model.presentPasswordPromptIfNeeded() } }
        .onChange(of: fps.showSettings) { _, shown in if !shown { model.presentPasswordPromptIfNeeded() } }
        .onChange(of: model.showPasswordPrompt) { _, shown in if shown { fps.releaseCapture() } }
    }

    private var connectionStatus: some View {
        HStack(spacing: 9) {
            HStack(spacing: 7) {
                Circle().fill(model.phase.color).frame(width: 7, height: 7)
                Text(model.phase.title).font(.system(size: 12, weight: .medium))
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(model.phase.color.opacity(0.09), in: Capsule())
            Button { AppResources.openReadme() } label: { Image(systemName: "questionmark.circle") }
                .help("打开 README")
        }
    }

    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if fps.isEditingLayout {

                                        Text(fps.profile.name).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                    FPSLayoutInspector(controller: fps).disabled(fps.layoutSaving)
                } else {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("iPad 设备").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                        Spacer()
                        Button { Task { await model.refresh() } } label: {
                            Image(systemName: "arrow.clockwise").font(.system(size: 12))
                        }.buttonStyle(.plain).disabled(model.scanning).help("刷新设备")
                    }
                    Picker("设备", selection: Binding(get: { model.selectedUDID }, set: { model.select($0) })) {
                        if model.devices.isEmpty { Text("等待 USB 连接…").tag(model.selectedUDID) }
                        ForEach(model.devices) { device in Text(device.name).tag(device.udid) }
                    }.labelsHidden().frame(maxWidth: .infinity).disabled(fps.isEditingLayout)
                    HStack(alignment: .top, spacing: 7) {
                        Image(systemName: "cable.connector").foregroundStyle(model.selectedDevice != nil ? .green : .orange)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(model.usbTitle).font(.system(size: 12, weight: .medium))
                            Text(model.usbAdvice).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                Divider()
                VStack(spacing: 9) {
                    Button {
                        if model.wantsConnection { model.stopConnection() } else { model.connect() }
                    } label: {
                        Label(model.wantsConnection ? (model.viewerConnected ? "断开连接" : "停止等待") : "连接 iPad", systemImage: model.wantsConnection ? "stop.circle" : "play.fill")
                            .frame(maxWidth: .infinity).padding(.vertical, 3)
                    }.buttonStyle(PrimaryActionButtonStyle()).controlSize(.large)
                    Button { model.showInstaller = true } label: {
                        Label("安装 / 配置控制端", systemImage: "shippingbox")
                            .frame(maxWidth: .infinity).padding(.vertical, 3)
                    }.buttonStyle(.bordered).controlSize(.large)
                }
                Divider()
                fpsControls
                Divider()
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("断线自动重连", isOn: $model.autoReconnect).toggleStyle(.checkbox)
                }.font(.system(size: 11))
                VStack(alignment: .leading, spacing: 12) {
                    Button { model.showLogs.toggle() } label: {
                        Label(model.showLogs ? "收起诊断日志" : "诊断与日志", systemImage: "list.bullet.rectangle")
                    }.buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(.secondary)
                    Button { model.openScreenSharing() } label: {
                        Label("系统屏幕共享", systemImage: "arrow.up.forward.app")
                    }.buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(.secondary)
                        .disabled(model.localPort == nil).help("使用 macOS 屏幕共享作为备用画面客户端")
                }
                Text("USB 直连 · 应用内操作")
                    .font(.system(size: 10)).foregroundStyle(.tertiary).padding(.top, 8)
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.primary.opacity(0.06), lineWidth: 1))
    }

    private var fpsControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: $fps.enabled) {
                Label("FPS 游戏模式", systemImage: "gamecontroller")
                    .font(.system(size: 12, weight: .semibold))
            }.toggleStyle(.switch).controlSize(.small).disabled(fps.isEditingLayout)
            if fps.isEditingLayout {
                FPSLayoutInspector(controller: fps)
            } else if fps.enabled {
                Picker("键位配置", selection: Binding(get: { fps.selectedProfileID }, set: { fps.selectProfile($0) })) {
                    ForEach(fps.profileNames) { Text($0.name).tag($0.id) }
                }.labelsHidden().font(.system(size: 11))
                Button { fps.beginLayoutEditing() } label: {
                    Label("拖拽布局…", systemImage: "cursorarrow.and.square.on.square.dashed").frame(maxWidth: .infinity)
                }.buttonStyle(PrimaryActionButtonStyle()).disabled(!fps.videoReady).font(.system(size: 12))
                HStack {
                    Button("按键与灵敏度…") { fps.showSettings = true }
                    Spacer()
                    Button { fps.toggleCapture() } label: {
                        Image(systemName: fps.captured ? "pause.fill" : "cursorarrow.motionlines")
                    }.help(fps.captured ? "释放输入 · F8" : "捕获鼠标 · F8")
                        .disabled(!fps.ready || fps.calibration != nil)
                }.font(.system(size: 11))
                Toggle("显示触控位置", isOn: $fps.showMarkers).toggleStyle(.checkbox).font(.system(size: 11))
                Button { fps.showGameCursor() } label: {
                    Label("呼出鼠标", systemImage: "cursorarrow").frame(maxWidth: .infinity)
                }.disabled(!fps.ready || fps.calibration != nil)
                    .help("显示鼠标后左键点击游戏；按 \(FPSKey.title(fps.profile.cursorToggleKey)) 恢复转向")
                    .font(.system(size: 12))
                Text("\(FPSKey.title(fps.profile.cursorToggleKey)) 呼出 / 收回鼠标")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                if fps.ready {
                    Text(fps.deviceCursorHint)
                        .font(.system(size: 11)).foregroundStyle(fps.deviceCursorAvailable ? Color.secondary : Color.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(fps.status).font(.system(size: 11)).foregroundStyle(fps.ready ? Color.secondary : Color.orange)
                    .fixedSize(horizontal: false, vertical: true)
                if !fps.lastAction.isEmpty {
                    Text("最近动作：\(fps.lastAction)").font(.system(size: 10)).foregroundStyle(.secondary)
                }
                if let ms = fps.roundTripMilliseconds {
                    Text("输入往返 \(ms, specifier: "%.1f") ms · \(fps.remoteContacts) 个触点")
                        .font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary)
                }
            } else {
                Text("WASD 移动、鼠标转向、多点同时开火。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var viewerCard: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Label("iPad 画面", systemImage: "ipad.landscape").font(.system(size: 13, weight: .medium))
                Spacer()
                if fps.enabled {
                    Button { fps.showGameCursor() } label: {
                        Label("呼出鼠标", systemImage: "cursorarrow")
                    }.disabled(!fps.ready || fps.isEditingLayout || fps.calibration != nil)
                        .help("左键点击游戏；按 \(FPSKey.title(fps.profile.cursorToggleKey)) 恢复转向")
                }
                Button("拖拽布局…") { fps.beginLayoutEditing() }
                    .disabled(!fps.videoReady || fps.isEditingLayout)
                Button { model.viewerDriver.home() } label: { Image(systemName: "house") }
                    .help("返回 iPad 主屏幕").disabled(!model.viewerConnected)
                Button { model.viewerDriver.power() } label: { Image(systemName: "lock") }
                    .help("iPad 电源键 / 锁屏").disabled(!model.viewerConnected)
                Button { model.showTextSender = true } label: { Image(systemName: "text.cursor") }
                    .help(fps.enabled ? "关闭 FPS 模式后可发送文本" : "发送中文或长文本")
                    .disabled(!model.viewerConnected || fps.enabled)
                Button { NSApp.keyWindow?.toggleFullScreen(nil) } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                    .help("全屏显示")
                connectionStatus
            }
            .buttonStyle(ToolbarActionButtonStyle()).padding(.horizontal, 17).padding(.vertical, 14)
            Divider()
            if fps.isEditingLayout {
                HStack(spacing: 12) {
                    Label("拖拽布局", systemImage: "square.and.pencil").foregroundStyle(.blue)
                    Button { fps.undoLayout() } label: { Image(systemName: "arrow.uturn.backward") }
                        .disabled(fps.layoutSaving || fps.layoutEditor?.canUndo != true).help("撤销 · ⌘Z").accessibilityLabel("撤销布局调整")
                    Button { fps.redoLayout() } label: { Image(systemName: "arrow.uturn.forward") }
                        .disabled(fps.layoutSaving || fps.layoutEditor?.canRedo != true).help("重做 · ⇧⌘Z").accessibilityLabel("重做布局调整")
                    Spacer(minLength: 0)
                    if fps.layoutSaving { ProgressView().controlSize(.small) }
                    Button("取消") { fps.cancelLayoutEditing() }.disabled(fps.layoutSaving)
                    Button(fps.layoutSaving ? "正在保存…" : "保存布局") { fps.saveLayout() }
                        .buttonStyle(PrimaryActionButtonStyle()).disabled(fps.layoutSaving)
                }.font(.system(size: 12)).padding(.horizontal, 16).padding(.vertical, 10)
                    .background(Color.blue.opacity(0.05))
                Divider()
            }
            ZStack {
                Color(red: 0.065, green: 0.09, blue: 0.13)
                if let url = model.viewerURL {
                    ViewerView(model: model, fps: fps, url: url)
                } else {
                    VStack(spacing: 18) {
                        Image(systemName: "ipad.landscape").font(.system(size: 72, weight: .ultraLight)).foregroundStyle(Color.white.opacity(0.28))
                        VStack(spacing: 10) {
                            Text(model.wantsConnection ? model.phase.title : "iPad 画面将在这里显示")
                                .font(.system(size: 19, weight: .medium)).foregroundStyle(.white.opacity(0.86))
                            Text(model.detail).font(.system(size: 12)).foregroundStyle(.white.opacity(0.50))
                                .multilineTextAlignment(.center).lineSpacing(4).frame(maxWidth: 380).fixedSize(horizontal: false, vertical: true)
                        }
                        if model.phase == .waitingServer {
                            Button("安装 iPad 控制端") { model.showInstaller = true }
                                .buttonStyle(PrimaryActionButtonStyle()).padding(.top, 2)
                        }
                    }.padding(30)
                }
                if model.isDemo {
                    VStack { Spacer(); Text("模拟设备 · 仅用于界面测试").font(.system(size: 10)).foregroundStyle(.orange).padding(8) }
                        .allowsHitTesting(false)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack(spacing: 20) {
                if fps.isEditingLayout {
                    Label("拖动移动 / 四角缩放", systemImage: "cursorarrow.and.square.on.square.dashed")
                    Label("⌘Z 撤销 · ⌘S 保存", systemImage: "keyboard")
                } else if fps.calibration != nil {
                    Label("点击画面标定：\(fps.calibrationTitle)", systemImage: "scope")
                    Button("取消标定") { fps.cancelCalibration() }.buttonStyle(.plain).foregroundStyle(.blue)
                } else if fps.enabled {
                    Label("WASD 移动", systemImage: "keyboard")
                    Label(fps.cursorMode ? "鼠标点击 / 拖动" : "鼠标转向 / 开火", systemImage: "cursorarrow.motionlines")
                    Label("\(FPSKey.title(fps.profile.cursorToggleKey)) 切换鼠标", systemImage: "cursorarrow")
                    Label(fps.captured ? "F8 释放" : "点击画面 / F8 捕获", systemImage: "keyboard")
                } else {
                    Label("左键触摸 / 拖动", systemImage: "cursorarrow.click")
                    Label("滚轮滑动", systemImage: "scroll")
                    Label("右键主屏幕", systemImage: "house")
                }
                Spacer(minLength: 0)
            }.font(.system(size: 10)).foregroundStyle(.secondary).padding(.horizontal, 16).padding(.vertical, 12)
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.primary.opacity(0.06), lineWidth: 1))
    }

    private var logsPanel: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("诊断与日志").font(.system(size: 12, weight: .semibold))
                Spacer()
                Button("复制诊断") { model.copyDiagnostics() }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.blue)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(model.logs) { entry in
                            HStack(alignment: .top, spacing: 10) {
                                Text(entry.time, format: .dateTime.hour().minute().second()).foregroundStyle(.tertiary).frame(width: 60, alignment: .leading)
                                Text(entry.message).foregroundStyle(.secondary).textSelection(.enabled)
                            }.font(.system(size: 10, design: .monospaced)).id(entry.id)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: model.logs.count) { _, _ in if let id = model.logs.last?.id { proxy.scrollTo(id, anchor: .bottom) } }
            }.frame(height: 90)
        }
        .padding(14).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
    }
}

struct TextSenderView: View {
    @Environment(\.dismiss) private var dismiss
    let driver: ViewerDriver
    @State private var text = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("发送文本到 iPad").font(.title2.weight(.semibold))
            Text("先在 iPad 画面中点选输入框。文本会通过 iPad 剪贴板粘贴，适合中文和长文本。")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            TextEditor(text: $text).font(.system(size: 14)).frame(height: 180)
                .padding(6).overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.3)))
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("发送并粘贴") { driver.sendText(String(text.prefix(262144))); dismiss() }
                    .buttonStyle(PrimaryActionButtonStyle()).disabled(text.isEmpty).keyboardShortcut(.defaultAction)
            }
        }.padding(26).frame(width: 560)
    }
}

struct ControlPasswordView: View {
    @ObservedObject var model: ControlModel
    @FocusState private var passwordFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("连接 iPad").font(.title2.weight(.semibold))
            Text(model.detail).font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            SecureField("iPad 控制密码", text: $model.vncPassword)
                .textFieldStyle(.roundedBorder).focused($passwordFocused)
                .onSubmit { model.submitPassword() }
            Toggle("将控制密码保存在 Mac 钥匙串", isOn: $model.rememberPassword)
                .toggleStyle(.checkbox).font(.system(size: 11))
            HStack {
                Spacer()
                Button("取消连接") { model.stopConnection() }.keyboardShortcut(.cancelAction)
                Button("连接") { model.submitPassword() }
                    .buttonStyle(PrimaryActionButtonStyle()).disabled(model.vncPassword.isEmpty)
                    .keyboardShortcut(.defaultAction)
            }
        }.padding(26).frame(width: 420)
            .interactiveDismissDisabled()
            .onAppear { passwordFocused = true }
    }
}
