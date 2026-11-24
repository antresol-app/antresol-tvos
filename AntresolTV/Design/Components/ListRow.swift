import SwiftUI

/// A full-width list row (track lists, queue): transparent at rest, a soft
/// white glass plate when focused with the text turning black on white, like the design's pills.
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
            .environment(\.badgesOnLightPlate, isFocused)
            .foregroundStyle(isFocused ? Theme.Colors.labelInverse : Theme.Colors.label)
            .padding(.horizontal, Theme.Layout.listRowInset)
            .frame(minHeight: 84)
            .focusPlate(isFocused: isFocused, isPressed: configuration.isPressed)
    }
}

extension View {
    /// The focus of a row: a lit glass plate behind it, a gentle lift and a shadow. The
    /// defaults are a settings or list row's; the TV channel list's row has its own.
    func focusPlate(
        isFocused: Bool, isPressed: Bool, radius: CGFloat = Theme.Radius.control,
        scale: CGFloat = Theme.Motion.Focus.row, shadow: Theme.Shadow.Lift = Theme.Shadow.row
    ) -> some View {
        background {
            if isFocused {
                Color.clear.glassSurface(in: RoundedRectangle(cornerRadius: radius, style: .continuous), highlighted: true)
            }
        }
        .scaleEffect(isPressed ? Theme.Motion.Press.row : (isFocused ? scale : 1))
        .focusShadow(shadow, isFocused: isFocused)
        .animation(Theme.Motion.easeOut, value: isFocused)
    }
}

extension View {
    /// Widens a stack of `ListRowButtonStyle` rows by the rows' inner padding, so their text
    /// starts at the stack's edge and only the focus plate reaches beyond it.
    func listRowOutdent() -> some View {
        padding(.horizontal, -Theme.Layout.listRowInset)
    }
}

/// A round transport control (previous, play, next, shuffle...). Glass at rest, lit
/// white glass with a black glyph when focused; `isActive` tints the glyph for toggles that are on.
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
            .environment(\.roundGlyphPointSize, diameter * 0.36)
            .font(.system(size: diameter * 0.36, weight: .semibold))
            .foregroundStyle(foreground)
            .frame(width: diameter, height: diameter)
            .glassSurface(in: Circle(), highlighted: isFocused)
            .overlay(alignment: .bottom) {
                if isActive {
                    Circle()
                        .fill(isFocused ? Theme.Colors.labelInverse : Theme.Colors.accent)
                        .frame(width: 8, height: 8)
                        .padding(.bottom, diameter * 0.12)
                }
            }
            .scaleEffect(configuration.isPressed ? Theme.Motion.Press.circle : (isFocused ? Theme.Motion.Focus.pill : 1))
            .focusShadow(Theme.Shadow.circle, isFocused: isFocused)
            .opacity(isEnabled ? 1 : 0.4)
            .animation(Theme.Motion.easeOut, value: isFocused)
    }

    private var foreground: Color {
        if isFocused { return Theme.Colors.labelInverse }
        return isActive ? Theme.Colors.accent : Theme.Colors.label
    }
}
