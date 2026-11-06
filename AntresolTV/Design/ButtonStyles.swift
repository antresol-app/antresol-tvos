import SwiftUI

/// Pill-shaped action buttons from the design reference.
///
/// - `.primary`: the light "Play" pill with black text.
/// - `.glass`: the clear glass pill ("Details", secondary actions). It lights up white
///   when focused so focus is obvious from across the room.
///
/// Both are Liquid Glass on tvOS 26 (`glassSurface`), flat fills before it.
struct PillButtonStyle: ButtonStyle {
    enum Kind {
        case primary
        case glass
    }

    var kind: Kind = .glass

    func makeBody(configuration: Configuration) -> some View {
        PillButtonBody(configuration: configuration, kind: kind)
    }
}

private struct PillButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let kind: PillButtonStyle.Kind
    @Environment(\.isFocused) private var isFocused
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        configuration.label
            .font(Theme.Typography.button)
            .labelStyle(PillLabelStyle())
            .lineLimit(1)
            .foregroundStyle(foreground)
            .padding(.horizontal, 44)
            .frame(minHeight: 76)
            .glassSurface(in: Capsule(), highlighted: isFocused, prominent: kind == .primary)
            .scaleEffect(scale)
            .shadow(color: .black.opacity(isFocused ? 0.55 : 0), radius: 22, y: 12)
            .opacity(isEnabled ? 1 : 0.45)
            .animation(Theme.Motion.easeOut, value: isFocused)
            .animation(Theme.Motion.easeOut, value: configuration.isPressed)
    }

    private var isHighlighted: Bool {
        kind == .primary || isFocused
    }

    private var foreground: Color {
        isHighlighted ? Theme.Colors.labelInverse : Theme.Colors.label
    }

    private var scale: CGFloat {
        if configuration.isPressed { return 0.97 }
        return isFocused ? Theme.Motion.focusScale : 1
    }
}

/// Icon and title of a pill button, with tighter spacing than the default label style.
private struct PillLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 14) {
            configuration.icon
            configuration.title
        }
    }
}

/// A focus-aware button style for cards. The style itself only handles the press; it
/// publishes the focus state as `\.isCardFocused` so a card can lift its artwork alone
/// while the caption underneath stays in place, like the tvOS poster lockups.
struct CardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        CardButtonBody(configuration: configuration)
    }
}

private struct CardButtonBody: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        configuration.label
            .environment(\.isCardFocused, isFocused)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(Theme.Motion.easeOut, value: isFocused)
            .animation(Theme.Motion.easeOut, value: configuration.isPressed)
    }
}

private struct CardFocusedKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Whether the enclosing `CardButtonStyle` button has focus.
    var isCardFocused: Bool {
        get { self[CardFocusedKey.self] }
        set { self[CardFocusedKey.self] = newValue }
    }
}

extension View {
    /// The lift applied to focused card artwork: scale, soft shadow and a thin light rim.
    func cardLift(isFocused: Bool, cornerRadius: CGFloat = Theme.Radius.card) -> some View {
        self
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(.white.opacity(isFocused ? 0.85 : 0.08), lineWidth: isFocused ? 3 : 1)
            )
            .scaleEffect(isFocused ? Theme.Motion.cardLift : 1)
            .shadow(color: .black.opacity(isFocused ? 0.6 : 0.25), radius: isFocused ? 28 : 8, y: isFocused ? 18 : 4)
    }
}

/// A shelf title that opens the full list: plain text with a chevron, lifted onto a
/// white capsule when focused.
struct ShelfTitleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        ShelfTitleButtonBody(configuration: configuration)
    }
}

private struct ShelfTitleButtonBody: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        configuration.label
            .font(Theme.Typography.sectionTitle)
            .foregroundStyle(isFocused ? Theme.Colors.labelInverse : Theme.Colors.label)
            .padding(.horizontal, 24)
            .padding(.vertical, 8)
            .background {
                if isFocused { Color.clear.glassSurface(in: Capsule(), highlighted: true) }
            }
            .scaleEffect(configuration.isPressed ? 0.97 : (isFocused ? Theme.Motion.focusScale : 1))
            .animation(Theme.Motion.easeOut, value: isFocused)
    }
}
