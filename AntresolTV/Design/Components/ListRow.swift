import SwiftUI

/// A full-width list row (track lists, queue, chapters): transparent at rest, a soft
/// glass plate when focused with the text turning black on white, like the design's pills.
struct ListRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        ListRowBody(configuration: configuration)
    }
}

private struct ListRowBody: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        configuration.label
            .environment(\.isCardFocused, isFocused)
            .foregroundStyle(isFocused ? Theme.Colors.labelInverse : Theme.Colors.label)
            .padding(.horizontal, 28)
            .frame(minHeight: 84)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                    .fill(isFocused ? Color.white : Color.clear)
            )
            .scaleEffect(configuration.isPressed ? 0.99 : (isFocused ? 1.02 : 1))
            .shadow(color: .black.opacity(isFocused ? 0.45 : 0), radius: 18, y: 10)
            .animation(Theme.Motion.easeOut, value: isFocused)
    }
}

/// A round transport control (previous, play, next, shuffle...). Glass at rest, white
/// with a black glyph when focused; `isActive` tints the glyph for toggles that are on.
struct CircleButtonStyle: ButtonStyle {
    var diameter: CGFloat = 96
    var isActive = false

    func makeBody(configuration: Configuration) -> some View {
        CircleButtonBody(configuration: configuration, diameter: diameter, isActive: isActive)
    }
}

private struct CircleButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let diameter: CGFloat
    let isActive: Bool
    @Environment(\.isFocused) private var isFocused
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        configuration.label
            .labelStyle(.iconOnly)
            .font(.system(size: diameter * 0.36, weight: .semibold))
            .foregroundStyle(foreground)
            .frame(width: diameter, height: diameter)
            .background(isFocused ? Color.white : Theme.Colors.glassFill, in: Circle())
            .overlay(Circle().strokeBorder(isFocused ? .clear : Theme.Colors.glassBorder, lineWidth: 1.5))
            .overlay(alignment: .bottom) {
                if isActive {
                    Circle()
                        .fill(isFocused ? Theme.Colors.labelInverse : Theme.Colors.accent)
                        .frame(width: 8, height: 8)
                        .padding(.bottom, diameter * 0.12)
                }
            }
            .scaleEffect(configuration.isPressed ? 0.95 : (isFocused ? Theme.Motion.focusScale : 1))
            .shadow(color: .black.opacity(isFocused ? 0.5 : 0), radius: 18, y: 10)
            .opacity(isEnabled ? 1 : 0.4)
            .animation(Theme.Motion.easeOut, value: isFocused)
    }

    private var foreground: Color {
        if isFocused { return Theme.Colors.labelInverse }
        return isActive ? Theme.Colors.accent : Theme.Colors.label
    }
}
