import SwiftUI

struct PrimaryActionButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.controlSize) private var controlSize

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, controlSize == .large ? 14 : 10)
            .padding(.vertical, controlSize == .large ? 7 : 5)
            .foregroundStyle(isEnabled ? Color.white : Color.gray)
            .background(isEnabled ? Color.accentColor.opacity(configuration.isPressed ? 0.75 : 1) : Color.gray.opacity(0.20),
                        in: RoundedRectangle(cornerRadius: 6))
    }
}

struct CursorActionButtonStyle: ButtonStyle {
    var isActive: Bool
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .fontWeight(.semibold)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .foregroundStyle(isEnabled ? Color.accentColor : Color.gray)
            .background(isEnabled ? Color.accentColor.opacity(configuration.isPressed ? 0.22 : (isActive ? 0.16 : 0.07)) : Color.gray.opacity(0.20),
                        in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6)
                .stroke(isEnabled ? Color.accentColor.opacity(0.65) : Color.gray.opacity(0.25), lineWidth: 1))
    }
}

struct ToolbarActionButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(isEnabled ? Color.primary.opacity(0.65) : Color.gray)
            .padding(4)
            .background(configuration.isPressed && isEnabled ? Color.gray.opacity(0.15) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
    }
}
