import SwiftUI
import IControlCore

struct FPSJoystickControls: View {
    @Binding var profile: FPSProfile
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("平滑换向", isOn: $profile.smoothKeyboardSteering).toggleStyle(.checkbox)
            if profile.smoothKeyboardSteering {
                Text("加按或松开一个方向键时，摇杆从当前位置转向新方向，到位前逐渐减速。全部松开即抬指。")
            } else {
                HStack {
                    Text("WASD 推杆过渡")
                    Slider(value: $profile.keyboardTurnDuration, in: FPSProfile.keyboardTurnDurationRange)
                        .accessibilityLabel("WASD 推杆过渡")
                    Text("\(Int((profile.keyboardTurnDuration * 1000).rounded())) ms").monospacedDigit()
                }
                Button("即时换向") { profile.keyboardTurnDuration = 0 }
                Text("手动模式：松开的轴直接归零。过渡时间按一个半径计算，完全反向用时加倍。")
            }
            Text("请将中心十字对准游戏摇杆的静止中心，并将推杆距离设在游戏摇杆的活动范围内。")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.font(.system(size: 11))
    }
}
