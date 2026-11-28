import AppKit
import SwiftUI

struct IPadAudioControls: View {
    @ObservedObject var controller: IPadAudioController

    var body: some View {
        let state = controller.state
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: Binding(get: { controller.enabled }, set: { controller.setEnabled($0) })) {
                Label("iPad 游戏声音", systemImage: "speaker.wave.2")
                    .font(.system(size: 12, weight: .semibold))
            }.toggleStyle(.switch).controlSize(.small)
            if controller.enabled {
                if !state.sources.isEmpty {
                    Picker("iPad 音频输入", selection: Binding(get: { state.sourceID ?? "" }, set: { controller.select($0) })) {
                        if state.sourceID == nil { Text("选择 iPad 输入…").tag("") }
                        ForEach(state.sources) { source in
                            // Keep same-name endpoints distinguishable even when their UIDs share a suffix.
                            Text(source.name + (state.sources.filter { $0.name == source.name }.count > 1 ? " · \(source.id)" : ""))
                                .tag(source.id).help(source.id)
                        }
                    }.labelsHidden().controlSize(.small).frame(maxWidth: .infinity)
                }
                Text(state.message).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    .help("有输入电平但听不到？检查 Mac 的“系统设置 → 声音 → 输出”以及输出音量。")
                if state.action == .setup {
                    Text("用数据线连接并解锁 iPad、信任此 Mac。在“窗口 → 显示音频设备”中点 iPad 旁的“启用”。无需更改 Mac 默认输入。")
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Button("打开音频 MIDI 设置") {
                        let workspace = NSWorkspace.shared
                        let app = workspace.urlForApplication(withBundleIdentifier: "com.apple.audio.AudioMIDISetup")
                            ?? URL(fileURLWithPath: "/System/Applications/Utilities/Audio MIDI Setup.app")
                        workspace.openApplication(at: app, configuration: .init(), completionHandler: nil)
                    }
                }
                if state.action == .privacy {
                    Button("打开麦克风隐私设置") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
                if state.action == .retry || state.action == .privacy { Button("重试音频监听") { controller.retry() } }
            }
        }.font(.system(size: 11)).controlSize(.small)
    }
}
