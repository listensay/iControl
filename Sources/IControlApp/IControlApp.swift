import SwiftUI
import AppKit
import IControlCore

enum AppResources {
    static let version = "1.4.5"
    static var build: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "13" }
    static func openReadme() {
        NSWorkspace.shared.open(root.appendingPathComponent("README.md"))
    }
    static var root: URL {
        if let location = Bundle.main.resourceURL?.appendingPathComponent("iControl_IControlApp.bundle/Resources"),
           FileManager.default.fileExists(atPath: location.path) { return location }
        return Bundle.module.resourceURL!.appendingPathComponent("Resources")
    }
    static var support: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("iControl", isDirectory: true)
    }
}

enum CommandLineMode {
    static func handle() {
        let environment = ProcessInfo.processInfo.environment
        if environment["ICONTROL_ASKPASS"] == "1" {
            do {
                let password = try AskpassServer.reply(environment: environment, prompt: CommandLine.arguments.dropFirst().first ?? "")
                FileHandle.standardOutput.write(Data((password + "\n").utf8))
                exit(0)
            } catch { exit(1) }
        }
        if CommandLine.arguments.contains("--version") {
            print("iControl \(AppResources.version) (\(AppResources.build))")
            exit(0)
        }
        if CommandLine.arguments.contains("--verify-resources") {
            do {
                let root = AppResources.root
                for file in ["README.md", "README.zh-CN.md", "docs/SETUP.md", "docs/SETUP.zh-CN.md", "Viewer/index.html", "Viewer/viewer.js", "Viewer/fps-overlay.js", "Viewer/novnc/core/rfb.js", "Licenses/noVNC-LICENSE.MPL-2.0.txt", "ThirdPartySources/TrollVNC-v3.2-272-source.tar.gz", "FPSDaemon/COPYING", "FPSDaemon/HIDBridge.h", "FPSDaemon/CursorHosting-NOTICE.txt", "ThirdPartySources/iControl-FPSDaemon-1.4.0-source.tar.gz"] {
                    guard FileManager.default.fileExists(atPath: root.appendingPathComponent(file).path) else { throw ControlError("缺少资源：\(file)") }
                }
                for package in [ServerPackage.rootless, .rootful] { _ = try package.verifiedData(in: root.appendingPathComponent("ServerPackages")) }
                _ = try FPSDaemonPackage.verifiedData(in: root)
                print("Bundled viewer, FPS daemon hash, source archives, licenses, and both official package hashes: OK")
                exit(0)
            } catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
        }
        if CommandLine.arguments.contains("--diagnose") {
            let mux = USBMux()
            var result: [String: Any] = ["appVersion": AppResources.version, "physicalIPadPresent": USBHardware.iPadPresent()]
            do {
                let devices = try mux.devices()
                result["usbDeviceCount"] = devices.count
                result["devices"] = devices.map { device -> [String: Any] in
                    let detail = (try? mux.details(for: device)) ?? device
                    var item: [String: Any] = ["name": detail.name, "model": detail.productType, "system": detail.version]
                    do { item["controlService"] = try mux.vncGreeting(device: detail) } catch { item["controlService"] = error.localizedDescription }
                    do {
                        let socket = try mux.connect(deviceID: detail.deviceID, port: FPSWire.port)
                        defer { socket.close() }
                        let greeting = try socket.read(count: 8, timeout: 1000)
                        item["fpsService"] = greeting == FPSWire.greeting ? "1.4.0，支持 iPad 指针"
                            : greeting == FPSWire.touchOnlyGreeting ? "1.3.0，iPad 指针需要升级至 1.4.0"
                            : greeting == FPSWire.legacyGreeting ? "旧版，需要升级至 1.4.0" : "未知控制端"
                    } catch { item["fpsService"] = error.localizedDescription }
                    return item
                }
            } catch { result["usbError"] = error.localizedDescription }
            if let json = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) {
                FileHandle.standardOutput.write(json); print("")
            }
            exit(0)
        }
    }
}

@main
struct IControlApplication: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model: ControlModel

    init() {
        CommandLineMode.handle()
        _model = StateObject(wrappedValue: ControlModel())
    }

    var body: some Scene {
        WindowGroup("iControl", id: "main") {
            ContentView(model: model)
                .onAppear { appDelegate.model = model; model.start() }
        }
        .defaultSize(width: 1050, height: 740)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) { }
            CommandGroup(replacing: .help) {
                Button("打开 README") { AppResources.openReadme() }
            }
            CommandMenu("iPad") {
                Button(model.wantsConnection ? "断开连接" : "连接 iPad") {
                    if model.wantsConnection { model.stopConnection() } else { model.connect() }
                }.keyboardShortcut("k", modifiers: .command)
                Button("安装 / 配置控制端") { model.showInstaller = true }
                Divider()
                Button("返回主屏幕") { model.viewerDriver.home() }.disabled(!model.viewerConnected)
                Button("发送文本…") { model.showTextSender = true }.disabled(!model.viewerConnected || model.fpsController.enabled)
                Divider()
                FPSMenuItems(controller: model.fpsController)
            }
        }
    }
}

private struct FPSMenuItems: View {
    @ObservedObject var controller: FPSController
    var body: some View {
        Group {
            Button("拖拽 FPS 布局…") { controller.beginLayoutEditing() }
                .disabled(!controller.videoReady || controller.isEditingLayout)
            Button("FPS 按键与灵敏度…") { controller.showSettings = true }
                .disabled(controller.isEditingLayout)
            Button("保存 FPS 布局") { controller.saveLayout() }
                .keyboardShortcut("s", modifiers: .command).disabled(!controller.isEditingLayout || controller.layoutSaving)
            Button("撤销布局调整") { controller.undoLayout() }
                .keyboardShortcut("z", modifiers: .command).disabled(controller.layoutSaving || controller.layoutEditor?.canUndo != true)
            Button("重做布局调整") { controller.redoLayout() }
                .keyboardShortcut("z", modifiers: [.command, .shift]).disabled(controller.layoutSaving || controller.layoutEditor?.canRedo != true)
            Button("捕获 / 释放游戏鼠标") { controller.toggleCapture() }
                .keyboardShortcut(KeyEquivalent(Character(UnicodeScalar(NSF8FunctionKey)!)), modifiers: [])
                .disabled(controller.isEditingLayout)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: ControlModel?
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        model?.fpsController.layoutSaving == true ? .terminateCancel : .terminateNow
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) { MainActor.assumeIsolated { model?.shutdown() } }
}
