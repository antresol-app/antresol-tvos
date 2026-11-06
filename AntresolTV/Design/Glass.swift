import SwiftUI

/// Liquid Glass on tvOS 26 and later, the app's flat dark-glass look before it.
///
/// Controls the app draws itself (pills, round transport buttons, segmented pills, settings
/// rows) use these so they share the system material: clear glass at rest, glass lit white
/// when focused (the system's focus highlight), with the lift the style adds on top.
extension View {
    /// Fills `shape` with glass behind the view. `highlighted` is the focused / selected
    /// state: bright white glass that takes dark text. `interactive` is for controls (the
    /// glass reacts to focus and presses); passive surfaces such as banners pass false.
    @ViewBuilder
    func glassSurface<S: InsettableShape>(in shape: S, highlighted: Bool, prominent: Bool = false, interactive: Bool = true) -> some View {
        if #available(tvOS 26.0, *) {
            self.glassEffect(Self.glass(highlighted: highlighted, prominent: prominent, interactive: interactive), in: shape)
        } else {
            self
                .background(highlighted || prominent ? Color.white : Theme.Colors.glassFill, in: shape)
                .overlay(shape.strokeBorder(highlighted || prominent ? .clear : Theme.Colors.glassBorder, lineWidth: 1.5))
        }
    }

    @available(tvOS 26.0, *)
    private static func glass(highlighted: Bool, prominent: Bool, interactive: Bool) -> Glass {
        let glass: Glass
        if highlighted {
            glass = .regular.tint(.white)
        } else if prominent {
            // The primary action (Play) stays a near-white pill at rest, like the TV app's;
            // focus adds the lift and shadow.
            glass = .regular.tint(Theme.Colors.glassProminentTint)
        } else {
            glass = .regular
        }
        return glass.interactive(interactive)
    }
}

/// Groups neighbouring glass controls so they sample one backdrop and render as one
/// material on tvOS 26; nothing before it. Shapes do not blend into each other (merge
/// distance 0): a focused pill lifting towards its neighbour would otherwise grow a bridge.
struct GlassGroup<Content: View>: View {
    /// The row's spacing, for call sites; the container itself never merges shapes.
    var spacing: CGFloat = 24
    @ViewBuilder let content: () -> Content

    var body: some View {
        if #available(tvOS 26.0, *) {
            GlassEffectContainer(spacing: 0) { content() }
        } else {
            content()
        }
    }
}
