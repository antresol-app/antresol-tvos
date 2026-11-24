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

    /// Which part of a pill that is split in two (a button and its menu button, side by side):
    /// the corners that face the other part are tight, the outer ones round.
    enum Segment {
        case whole
        /// The button; the menu button follows it.
        case leading
        /// The menu button after the button: a narrower pill that holds a glyph.
        case trailing
    }

    var kind: Kind = .glass
    /// A countdown filling the pill from the left (0…1), e.g. «Следующая серия».
    var fill: Double?
    var segment: Segment = .whole

    func makeBody(configuration: Configuration) -> some View {
        PillButtonBody(configuration: configuration, kind: kind, fill: fill, segment: segment)
    }
}

private struct PillButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let kind: PillButtonStyle.Kind
    let fill: Double?
    let segment: PillButtonStyle.Segment
    @Environment(\.isFocused) private var isFocused
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        configuration.label
            .font(Theme.Typography.button)
            .labelStyle(PillLabelStyle())
            .lineLimit(1)
            .foregroundStyle(foreground)
            .padding(.horizontal, segment == .trailing ? 30 : 44)
            .frame(minHeight: 76)
            // Inside the glass (its content), so the system material does not cover it.
            .background(alignment: .leading) {
                if let fill {
                    GeometryReader { proxy in
                        Rectangle()
                            .fill(Color.black.opacity(0.2))
                            .frame(width: proxy.size.width * min(1, max(0, fill)))
                    }
                    .clipShape(Capsule())
                    .allowsHitTesting(false)
                }
            }
            .modifier(PillSurface(segment: segment, highlighted: isFocused, prominent: kind == .primary))
            .scaleEffect(scale)
            .focusShadow(Theme.Shadow.pill, isFocused: isFocused)
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
        if configuration.isPressed { return Theme.Motion.Press.control }
        return isFocused ? Theme.Motion.Focus.pill : 1
    }
}

/// The glass behind a pill: a capsule, or for a part of a split pill the capsule with its facing corners tight.
private struct PillSurface: ViewModifier {
    let segment: PillButtonStyle.Segment
    let highlighted: Bool
    let prominent: Bool

    func body(content: Content) -> some View {
        switch segment {
        case .whole:
            content.glassSurface(in: Capsule(), highlighted: highlighted, prominent: prominent)
        case .leading:
            content.glassSurface(in: shape(leading: 38, trailing: 12), highlighted: highlighted, prominent: prominent)
        case .trailing:
            content.glassSurface(in: shape(leading: 12, trailing: 38), highlighted: highlighted, prominent: prominent)
        }
    }

    private func shape(leading: CGFloat, trailing: CGFloat) -> UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            cornerRadii: RectangleCornerRadii(topLeading: leading, bottomLeading: leading, bottomTrailing: trailing, topTrailing: trailing),
            style: .continuous
        )
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
            .scaleEffect(configuration.isPressed ? Theme.Motion.Press.control : 1)
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
            .scaleEffect(isFocused ? Theme.Motion.Focus.card : 1)
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
            .scaleEffect(configuration.isPressed ? Theme.Motion.Press.control : (isFocused ? Theme.Motion.Focus.pill : 1))
            .animation(Theme.Motion.easeOut, value: isFocused)
    }
}
