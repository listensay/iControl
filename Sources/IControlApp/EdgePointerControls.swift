import SwiftUI

struct EdgePointerControls: View {
    @ObservedObject var controller: EdgePointerController

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: $controller.enabled) {
                Label("鼠标跨屏", systemImage: "computermouse")
                    .font(.system(size: 12, weight: .semibold))
            }.toggleStyle(.switch).controlSize(.small)
            if controller.enabled {
                Picker("iPad 在 Mac 哪一侧", selection: $controller.side) {
                    ForEach(EdgePointerSide.allCases) { side in Text(side.title).tag(side) }
                }.labelsHidden().pickerStyle(.segmented).controlSize(.small)
                    .help("选择控制窗口所在屏幕的外边缘")
                Picker("触发热区", selection: $controller.zone) {
                    ForEach(EdgePointerZone.allCases) { zone in Text(zone.title(for: controller.side)).tag(zone) }
                }.font(.system(size: 11)).controlSize(.small)
                if controller.controlling {
                    Button("返回 Mac · Esc") { controller.release() }
                }
                Text(hint).font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .help("通过 USB 发送单点触摸。有可用的 iPad 游戏指针服务时，设备上也会显示位置。")
    }

    private var hint: String {
        if controller.session == nil { return "连接 iPad 并退出 FPS、布局编辑和弹窗后可用。" }
        if let problem = controller.problem { return problem }
        return controller.controlling
            ? "左键触摸或拖动。越过原接缝、按 Esc 或点右键返回。"
            : "控制窗口在前台时，移到屏幕\(controller.side.title)边的热区稍停；反向越过同一边缘返回。"
    }
}
