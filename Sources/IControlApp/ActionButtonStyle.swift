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

struct FPSActionButtonStyle: ButtonStyle {
    enum Role {
        case layout
        case cursor(isActive: Bool)
    }
    var role: Role
    var expandsToFill = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let isLayout: Bool
        let isActive: Bool
        switch role {
        case .layout: isLayout = true; isActive = false
        case .cursor(let active): isLayout = false; isActive = active
        }
        let shape = RoundedRectangle(cornerRadius: 6)
        let backgroundOpacity = isLayout ? (configuration.isPressed ? 0.75 : 1)
            : (configuration.isPressed ? 0.22 : (isActive ? 0.16 : 0.07))
        return configuration.label
            .font(.system(size: 12, weight: .semibold))
            .lineLimit(1)
            .padding(.horizontal, 10)
            .frame(width: expandsToFill ? nil : 112, height: 28)
            .frame(maxWidth: expandsToFill ? .infinity : nil)
            .foregroundStyle(isEnabled ? (isLayout ? Color.white : Color.accentColor) : Color.gray)
            .background(isEnabled ? Color.accentColor.opacity(backgroundOpacity) : Color.gray.opacity(0.20), in: shape)
            .overlay {
                if !isLayout {
                    shape.strokeBorder(isEnabled ? Color.accentColor.opacity(0.65) : Color.gray.opacity(0.25), lineWidth: 1)
                }
            }
            .contentShape(shape)
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
