import AntresolKit
import SwiftUI

/// Design tokens from docs/design-ref/DESIGN.md, scaled for a 1920x1080 point TV canvas
/// viewed from the couch (type and cards are larger than in the web TV layout).
enum Theme {
    enum Colors {
        static let background = Color.black
        static let raised = Color(hex: 0x121214)
        static let elevated = Color(hex: 0x1C1C1E)
        static let identityBackground = Color(hex: 0x0B0B10)
        static let label = Color(hex: 0xF5F5F7)
        static let label2 = Color(hex: 0xEBEBF5).opacity(0.7)
        static let label3 = Color(hex: 0xEBEBF5).opacity(0.45)
        static let labelInverse = Color.black
        static let accent = Color(hex: 0x0A84FF)
        static let green = Color(hex: 0x30D158)
        static let orange = Color(hex: 0xFF9F0A)
        static let red = Color(hex: 0xFF453A)
        static let fill = Color(hex: 0x787880).opacity(0.36)
        static let fillSecondary = Color(hex: 0x767680).opacity(0.16)
        static let hairline = Color.white.opacity(0.12)
        static let glassFill = Color(hex: 0x1C1C20).opacity(0.92)
        static let glassBorder = Color.white.opacity(0.08)
        /// Glass tint of the primary pill (Play) at rest: near-white, like the TV app's.
        static let glassProminentTint = Color.white.opacity(0.94)
        /// A focused but unselected option of a segmented pill.
        static let segmentFocusTint = Color.white.opacity(0.78)
        /// Lyric lines other than the current one, over the artwork colour.
        static let lyricInactive = Color.white.opacity(0.4)
    }

    enum Gradients {
        /// Brand tile gradient, #3a1c8c → #9b2fc9 at 160°.
        static let brand = LinearGradient(
            colors: [Color(hex: 0x3A1C8C), Color(hex: 0x9B2FC9)],
            startPoint: UnitPoint(x: 0.33, y: 0.03),
            endPoint: UnitPoint(x: 0.67, y: 0.97)
        )

        /// Profile avatar gradient (145°).
        static func avatar(_ preset: AvatarPreset) -> LinearGradient {
            LinearGradient(
                colors: [Color(hex: preset.colors.from), Color(hex: preset.colors.to)],
                startPoint: UnitPoint(x: 0.21, y: 0.09),
                endPoint: UnitPoint(x: 0.79, y: 0.91)
            )
        }

        /// Placeholder artwork for items without an image: a dark two-tone gradient whose
        /// hue is derived from `seed` (usually the title), stable across launches.
        static func placeholder(seed: String) -> LinearGradient {
            let tint = Theme.tint(for: seed)
            return LinearGradient(
                colors: [tint.opacity(0.95), tint.opacity(0.35)],
                startPoint: .top,
                endPoint: .bottom
            )
        }

        /// Bottom fade used under titles laid over artwork.
        static let scrim = LinearGradient(
            colors: [.clear, .black.opacity(0.75)],
            startPoint: .center,
            endPoint: .bottom
        )
    }

    enum Typography {
        static let heroTitle = Font.system(size: 84, weight: .bold)
        static let pageTitle = Font.system(size: 64, weight: .bold)
        static let sectionTitle = Font.system(size: 36, weight: .bold)
        static let headline = Font.system(size: 32, weight: .semibold)
        static let body = Font.system(size: 28, weight: .regular)
        static let meta = Font.system(size: 26, weight: .medium)
        static let eyebrow = Font.system(size: 22, weight: .semibold)
        static let cardTitle = Font.system(size: 24, weight: .semibold)
        static let cardMeta = Font.system(size: 20, weight: .regular)
        static let overlayTitle = Font.system(size: 28, weight: .bold)
        static let badge = Font.system(size: 17, weight: .semibold)
        static let button = Font.system(size: 28, weight: .semibold)
        static let segment = Font.system(size: 26, weight: .semibold)
        /// The outlined age rating on the Home hero.
        static let ratingBadge = Font.system(size: 18, weight: .bold)
        /// Synced lyric lines; plain (unsynced) lyrics are a step smaller.
        static let lyricLine = Font.system(size: 64, weight: .bold)
        static let lyricPlainLine = Font.system(size: 52, weight: .bold)
        /// The song title under the artwork on the lyrics page.
        static let lyricsTrackTitle = Font.system(size: 28, weight: .semibold)

        static func avatarInitial(size: CGFloat) -> Font {
            .system(size: size * 0.44, weight: .semibold, design: .rounded)
        }
    }

    enum Radius {
        static let card: CGFloat = 12
        static let smallCard: CGFloat = 10
        static let control: CGFloat = 12
        static let sheet: CGFloat = 20
        static let badge: CGFloat = 6
        static let ratingBadge: CGFloat = 4
    }

    enum Layout {
        /// Horizontal inset of page content (tvOS safe area is 80 pt).
        static let margin: CGFloat = 80
        static let shelfSpacing: CGFloat = 64
        static let cardSpacing: CGFloat = 40
        static let posterWidth: CGFloat = 240
        static let squareWidth: CGFloat = 300
        static let wideWidth: CGFloat = 500
        static let heroHeight: CGFloat = 1080
        /// How far the row under the Home hero rises into it.
        static let heroOverlap: CGFloat = 260
        /// Distance from the hero's bottom edge to its buttons, and to its page dots.
        static let heroContentInset: CGFloat = 285
        static let heroDotsInset: CGFloat = 225
        /// The hero's round icon buttons (watchlist, details, next).
        static let heroCircleButton: CGFloat = 76
        /// Lyrics page: the left column, its artwork and the space between lyric lines.
        static let lyricsColumnWidth: CGFloat = 560
        static let lyricsArtwork: CGFloat = 420
        static let lyricLineSpacing: CGFloat = 40
        /// Height of the artwork header on detail pages.
        static let detailHeaderHeight: CGFloat = 900
        /// Episode cards on a series page.
        static let episodeWidth: CGFloat = 420
        /// Poster grid cell width; six columns fit the 1760 pt content width.
        static let gridPosterWidth: CGFloat = 248
        static let gridSpacing: CGFloat = 46
        static let gridRowSpacing: CGFloat = 60
        /// Width between the page margins (1920 - 2 x 80).
        static let contentWidth: CGFloat = 1760
        /// Square cover grid cell; five columns fill the content width.
        static let gridSquareWidth: CGFloat = 316
        static let gridSquareSpacing: CGFloat = 45
        /// Inner padding of list rows (tracks, chapters, queue); lists are outdented by it
        /// so the row text lines up with the page's headings.
        static let listRowInset: CGFloat = 28
    }

    enum Motion {
        /// cubic-bezier(.22, 1, .36, 1)
        static let easeOut = Animation.timingCurve(0.22, 1, 0.36, 1, duration: 0.26)
        static let slowEaseOut = Animation.timingCurve(0.22, 1, 0.36, 1, duration: 0.6)
        static let focusScale: CGFloat = 1.07
        static let cardLift: CGFloat = 1.04
    }

    /// A saturated mid-dark colour derived from `seed`, used for placeholders and hero tints.
    static func tint(for seed: String) -> Color {
        // FNV-1a: `hashValue` is randomised per launch, this is not.
        var hash: UInt32 = 2_166_136_261
        for byte in seed.utf8 {
            hash = (hash ^ UInt32(byte)) &* 16_777_619
        }
        let hue = Double(hash % 360) / 360
        return Color(hue: hue, saturation: 0.55, brightness: 0.42)
    }
}

extension Color {
    /// A colour from a 24-bit RGB value such as 0x0A84FF.
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }
}
