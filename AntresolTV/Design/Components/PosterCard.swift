import AntresolKit
import SwiftUI

/// Artwork proportions used by cards.
enum ArtworkShape {
    /// 2:3 movie, series, book and comic posters.
    case poster
    /// 1:1 album, playlist and audiobook covers.
    case square
    /// Round artist portraits.
    case circle

    init(kind: ItemKind) {
        switch kind {
        case .album, .playlist, .audiobook: self = .square
        case .artist: self = .circle
        default: self = .poster
        }
    }

    /// Height divided by width.
    var aspectRatio: CGFloat {
        self == .poster ? 1.5 : 1
    }

    /// Default card width for this shape.
    var defaultWidth: CGFloat {
        self == .poster ? Theme.Layout.posterWidth : Theme.Layout.squareWidth
    }

    func cornerRadius(width: CGFloat) -> CGFloat {
        self == .circle ? width / 2 : Theme.Radius.card
    }
}

/// A poster lockup: rounded artwork (title overlay when there is no image), a progress bar
/// for started items, and title, year or context line and badges underneath. Use it as the
/// label of a button with `CardButtonStyle`; the artwork lifts when focused.
struct PosterCard: View {
    let card: Card
    var shape: ArtworkShape
    var width: CGFloat

    @Environment(\.isCardFocused) private var isFocused

    init(card: Card, shape: ArtworkShape? = nil, width: CGFloat? = nil) {
        self.card = card
        let resolved = shape ?? ArtworkShape(kind: card.kind)
        self.shape = resolved
        self.width = width ?? resolved.defaultWidth
    }

    var body: some View {
        VStack(alignment: shape == .circle ? .center : .leading, spacing: 0) {
            CardArtwork(
                title: card.title,
                paths: [card.poster],
                cornerRadius: cornerRadius,
                maxPixelSize: width * shape.aspectRatio * 2,
                showsPlaceholderTitle: shape != .circle
            )
            .overlay(alignment: .bottom) {
                if card.progress > 0, shape != .circle {
                    ProgressBar(value: card.progress)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 16)
                }
            }
            .frame(width: width, height: width * shape.aspectRatio)
            .cardLift(isFocused: isFocused, cornerRadius: cornerRadius)

            CardCaption(card: card, alignment: shape == .circle ? .center : .leading)
                .padding(.top, 20)
                .offset(y: isFocused ? 12 : 0)
        }
        .frame(width: width, alignment: shape == .circle ? .center : .leading)
        .accessibilityElement(children: .combine)
    }

    private var cornerRadius: CGFloat {
        shape.cornerRadius(width: width)
    }
}

/// A 16:9 card for continue-watching rows and episodes: backdrop (or poster) with a
/// progress bar, title and context line underneath.
struct WideCard: View {
    let card: Card
    var width: CGFloat = Theme.Layout.wideWidth

    @Environment(\.isCardFocused) private var isFocused

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CardArtwork(
                title: card.title,
                paths: [card.backdrop, card.poster],
                maxPixelSize: width * 2,
                placeholderAlignment: .topLeading
            )
            .overlay {
                if card.progress > 0 {
                    ZStack(alignment: .bottom) {
                        Theme.Gradients.scrim
                        ProgressBar(value: card.progress)
                            .padding(.horizontal, 20)
                            .padding(.bottom, 18)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
                }
            }
            .frame(width: width, height: width * 9 / 16)
            .cardLift(isFocused: isFocused)

            CardCaption(card: card, alignment: .leading, showsBadges: false)
                .padding(.top, 20)
                .offset(y: isFocused ? 12 : 0)
        }
        .frame(width: width, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// Title, secondary line and badges under a card.
struct CardCaption: View {
    let card: Card
    var alignment: HorizontalAlignment = .leading
    var showsBadges = true

    var body: some View {
        VStack(alignment: alignment, spacing: 6) {
            Text(verbatim: card.title)
                .font(Theme.Typography.cardTitle)
                .foregroundStyle(Theme.Colors.label)
                .lineLimit(1)
            if let secondary {
                Text(verbatim: secondary)
                    .font(Theme.Typography.cardMeta)
                    .foregroundStyle(Theme.Colors.label2)
                    .lineLimit(1)
            }
            if showsBadges, !card.badges.isEmpty {
                BadgeRow(badges: Array(card.badges.prefix(2)))
                    .padding(.top, 4)
            }
        }
    }

    /// The context line ("Artist", "Show · Season 1, Episode 2"), else the year.
    private var secondary: String? {
        if !card.subtitle.isEmpty { return card.subtitle }
        return card.year.map(String.init)
    }
}
