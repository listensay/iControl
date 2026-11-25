import SwiftUI
import IControlCore

struct FPSMouseAxisControls: View {
    @Binding var profile: FPSProfile

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("交换鼠标 X / Y", isOn: $profile.swapMouseAxes)
            HStack(spacing: 16) {
                Toggle("反转 X 轴", isOn: $profile.invertX)
                Toggle("反转 Y 轴", isOn: $profile.invertY)
            }
        }.toggleStyle(.checkbox)
    }
}

struct FPSMappingControls: View {
    @Binding var profile: FPSProfile
    let orientationDescription: String

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("触点坐标校准").font(.system(size: 12, weight: .semibold))
            Text(orientationDescription).foregroundStyle(.secondary)
            Picker("旋转补偿", selection: $profile.touchMapping.rotation) {
                Text("0° · 默认").tag(0)
                Text("90°").tag(1)
                Text("180°").tag(2)
                Text("270°").tag(3)
            }
            HStack(spacing: 16) {
                Toggle("镜像 X", isOn: $profile.touchMapping.mirrorX)
                Toggle("镜像 Y", isOn: $profile.touchMapping.mirrorY)
            }.toggleStyle(.checkbox)
            HStack(spacing: 8) {
                Text("X 偏移")
                offsetField("X 偏移百分比", value: $profile.touchMapping.offsetX)
                Text("Y 偏移")
                offsetField("Y 偏移百分比", value: $profile.touchMapping.offsetY)
            }
            Text("所有按键都偏位或轴向错位时调整旋转补偿，再用“测试点击”确认；只需改变鼠标转向时调整鼠标轴。")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Button("重置坐标校准") { profile.touchMapping = FPSCoordinateMapping() }
        }.font(.system(size: 11))
    }

    private func offsetField(_ label: String, value: Binding<Double>) -> some View {
        TextField(label, value: value, format: .percent.precision(.fractionLength(1)))
            .textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing)
            .monospacedDigit().frame(minWidth: 42, maxWidth: 62).accessibilityLabel(label)
    }
}
