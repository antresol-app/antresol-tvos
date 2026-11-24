import SwiftUI

/// The glyph of a round button, set where it looks centred rather than where its box is.
///
/// SF Symbols are laid out by their boxes, and a few have their ink off-centre: a chevron's ink sits right of its
/// middle, a star's mass low, a subtitles bubble's body above its tail. `GlyphOptics` moves those by a few hundredths
/// of the font size, which is the difference between a centred glyph and one that looks a little off.
struct RoundGlyph: View {
    let title: LocalizedStringKey
    let systemImage: String

    @Environment(\.roundGlyphPointSize) private var pointSize

    init(_ title: LocalizedStringKey, systemImage: String) {
        self.title = title
        self.systemImage = systemImage
    }

    var body: some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: systemImage)
                .offset(GlyphOptics.offset(for: systemImage, pointSize: pointSize))
        }
    }
}

extension EnvironmentValues {
    /// The point size of the glyph in a round button (its style sets it), the unit the offsets are in.
    @Entry var roundGlyphPointSize: CGFloat = 0
}

enum GlyphOptics {
    /// How far to move a symbol so its optical centre lies in the middle of its button, in em (the
    /// font size), x to the right and y down. Measured by `scripts/measure-glyph-centres.swift`: it draws the symbol
    /// as a round button does, takes the middle of the ink's box and the ink's centre of mass, and moves by minus their
    /// mean. Only moves of 0.02 em or more are listed. A symbol that is not here is centred as it is, as the
    /// play triangle is: its box sits right of the middle and its mass left of it, evenly.
    static let table: [String: CGSize] = [
        "chevron.right": CGSize(width: -0.059, height: 0),
        "checkmark": CGSize(width: 0, height: -0.023),
        "speaker.wave.2.fill": CGSize(width: 0.027, height: 0),
        "captions.bubble": CGSize(width: 0, height: 0.023),
        "captions.bubble.fill": CGSize(width: 0, height: 0.039),
        "star": CGSize(width: 0, height: -0.027),
        "star.fill": CGSize(width: 0, height: -0.027),
        "shuffle": CGSize(width: -0.036, height: 0),
        "delete.left": CGSize(width: -0.028, height: 0),
    ]

    static func offset(for symbol: String, pointSize: CGFloat) -> CGSize {
        guard let em = table[symbol] else { return .zero }
        return CGSize(width: em.width * pointSize, height: em.height * pointSize)
    }
}
