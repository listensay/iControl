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
            Text("斜走保留横向与纵向的完整推杆距离；加键、松键连续过渡，全部松开停止。上方时间为单轴完整位移，完全反向需两倍时间；0 ms 即时响应。相反方向优先后按的键。移动中心需要对准游戏摇杆中心，推杆距离在画面中调整；建议使用游戏的固定摇杆模式。")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.font(.system(size: 11))
    }
}
