import SwiftUI
import IControlCore

struct FPSJoystickControls: View {
    @Binding var profile: FPSProfile
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("WASD 推杆过渡")
                Slider(value: $profile.keyboardTurnDuration, in: FPSProfile.keyboardTurnDurationRange)
                    .accessibilityLabel("WASD 推杆过渡")
                Text("\(Int((profile.keyboardTurnDuration * 1000).rounded())) ms").monospacedDigit()
            }
            Button("即时换向") { profile.keyboardTurnDuration = 0 }
            Text("直走与斜走保持相同推杆半径，触点始终在圆圈内。松开 A / D 后立即清除横向偏移，只按 W 就沿正前方推杆；移动触点保持按住。上方时间为一个半径的过渡，完全反向需两倍时间；0 ms 即时响应。移动中心需对准游戏静止时的摇杆中心，推杆距离不能超过游戏摇杆的活动范围；建议使用固定摇杆模式。")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.font(.system(size: 11))
    }
}
