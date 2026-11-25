import SwiftUI
import IControlCore

struct FPSKeyLinkControls: View {
    @Binding var profile: FPSProfile
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("按键联动").font(.system(size: 14, weight: .semibold))
                Spacer()
                Button("添加联动") {
                    do { try profile.addKeyLink(); error = nil }
                    catch { self.error = error.localizedDescription }
                }.disabled(profile.keyLinks.count >= FPSProfile.maximumKeyLinks)
            }
            Text("例如 B → Esc：按 B 同时触发 B 和 Esc 的映射按钮。再添加 B → 呼出 / 收回游戏内鼠标，可同时切换鼠标模式。")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if profile.keyLinks.isEmpty { Text("暂无联动，点击“添加联动”开始配置。").foregroundStyle(.secondary) }
            ForEach($profile.keyLinks) { $link in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 10) {
                        Toggle("启用", isOn: $link.enabled).toggleStyle(.checkbox)
                        Picker("按下按键", selection: $link.source) {
                            ForEach(FPSKey.linkSources.filter { $0 != link.target }, id: \.self) {
                                Text(keyLabel($0)).tag($0)
                            }
                        }.frame(maxWidth: .infinity)
                        Image(systemName: "arrow.right")
                        Picker("同时触发", selection: $link.target) {
                            ForEach(FPSKey.linkTargets.filter { $0 != link.source }, id: \.self) {
                                Text(keyLabel($0)).tag($0)
                            }
                        }.frame(maxWidth: .infinity)
                        Button("删除", role: .destructive) {
                            let id = link.id; profile.keyLinks.removeAll { $0.id == id }
                        }
                    }
                    if link.target != FPSKey.cursorAction, !profile.buttons.contains(where: { $0.enabled && $0.trigger == link.target }) {
                        Text("\(FPSKey.title(link.target)) 尚未绑定启用的游戏按钮，请在动作按键中设置。")
                            .foregroundStyle(.orange)
                    }
                }.padding(10).background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
            }
            Text("松开主键时一起抬起按住型按钮；单独按住的联动键会继续保持。点按和滑动按各自方式完成。鼠标模式只在按下时切换，松键不切回；再按一次收回鼠标。联动仅影响动作键，WASD 与 F8 保留原有功能。")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let error { Text(error).foregroundStyle(.red) }
        }.font(.system(size: 11))
    }

    private func keyLabel(_ key: String) -> String {
        let title = FPSKey.title(key)
        guard key != FPSKey.cursorAction,
              let button = profile.buttons.first(where: { $0.enabled && $0.trigger == key }) else { return title }
        return title + " · " + button.title
    }
}
