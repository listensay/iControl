import SwiftUI
import IControlCore

struct FPSSwipeControls: View {
    let start: FPSPoint
    @Binding var swipe: FPSSwipe
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("滑动方向", selection: Binding(get: { swipe.direction(from: start) }, set: {
                swipe.set(direction: $0, distance: max(0.05, swipe.distance(from: start)), from: start)
            })) {
                ForEach(FPSSwipeDirection.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            HStack {
                Text("滑动距离")
                TextField("滑动距离", value: Binding(get: { swipe.distance(from: start) }, set: { value in
                    guard value.isFinite else { return }
                    swipe.set(direction: swipe.direction(from: start), distance: value, from: start)
                }), format: .percent.precision(.fractionLength(1))).textFieldStyle(.roundedBorder)
            }
            HStack {
                Text("时长（秒）")
                TextField("滑动时长", value: $swipe.duration, format: .number.precision(.fractionLength(2)))
                    .textFieldStyle(.roundedBorder)
                Stepper("滑动时长", value: $swipe.duration, in: 0.08...2, step: 0.05).labelsHidden()
            }
            Text("起点与终点在画面中拖动调整。按一次完成一次滑动；松开按键仍会完成路径。F8、断线或切换窗口会立即释放。")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.font(.system(size: 11))
    }
}

struct FPSAddMappingMenu: View {
    let profile: FPSProfile
    let custom: () -> Void
    let swipe: () -> Void
    let preset: (String) -> Void
    var body: some View {
        Menu {
            Button("自定义触摸按钮", action: custom).disabled(profile.customButtons.count >= FPSProfile.maximumCustomButtons)
            Button("滑动按钮（上 / 下 / 左 / 右）", action: swipe).disabled(profile.customButtons.count >= FPSProfile.maximumCustomButtons)
            Divider()
            if !profile.joystickEnabled { Button("WASD 移动摇杆") { preset("joystick") } }
            if !profile.lookEnabled { Button("鼠标转向区域") { preset("look") } }
            ForEach(FPSAction.allCases.filter { action in !profile.bindings.contains { $0.action == action } }) { action in
                Button(action.title) { preset(action.id) }
            }
        } label: { Label("添加映射", systemImage: "plus.circle.fill") }
    }
}
