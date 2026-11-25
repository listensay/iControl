import SwiftUI
import IControlCore

struct FPSJoystickControls: View {
    @Binding var profile: FPSProfile
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("WASD 换向过渡")
                Slider(value: $profile.keyboardTurnDuration, in: FPSProfile.keyboardTurnDurationRange)
                    .accessibilityLabel("WASD 换向过渡")
                Text("\(Int((profile.keyboardTurnDuration * 1000).rounded())) ms").monospacedDigit()
            }
            Button("即时换向") { profile.keyboardTurnDuration = 0 }
            Toggle("斜走松键时重置摇杆中心", isOn: $profile.keyboardRecenterOnAxisRelease)
                .accessibilityLabel("斜走松键时重置摇杆中心")
            Text("默认开启归位：例如 W+A 松开 A 后，移动触点短暂抬起，在画面中设定的摇杆中心重新按下，再向正前方推；开火、开镜和转视角继续响应。归位需要约 33–50 ms；固定摇杆可关闭此项，使用直接换向。请把画面中的移动中心对准游戏摇杆中心。相反方向优先后按的键；换向过渡用于加入方向键时的斜向转动。鼠标用于转视角。")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.font(.system(size: 11))
    }
}
