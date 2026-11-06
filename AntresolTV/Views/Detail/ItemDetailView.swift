import AntresolKit
import SwiftUI

/// The detail route for a card, by kind.
struct ItemDetailView: View {
    let card: Card

    var body: some View {
        switch card.kind {
        case _ where card.kind.isVideo: VideoDetailView(card: card)
        case .album: AlbumDetailView(card: card)
        case .artist: ArtistDetailView(card: card)
        case .playlist: PlaylistDetailView(card: card)
        default: ItemSummaryView(card: card)
        }
    }
}

/// Artwork-tinted header with the kind, title, context line and badges of a card, for
/// kinds this app has no page for.
struct ItemSummaryView: View {
    let card: Card

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            HeroBackground(card: card)
                .ignoresSafeArea()
            VStack(alignment: .leading, spacing: 22) {
                if !card.kind.displayName.isEmpty {
                    Text(verbatim: card.kind.displayName)
                        .font(Theme.Typography.eyebrow)
                        .tracking(2)
                        .textCase(.uppercase)
                        .foregroundStyle(Theme.Colors.label2)
                }
                Text(verbatim: card.title)
                    .font(Theme.Typography.heroTitle)
                    .foregroundStyle(Theme.Colors.label)
                    .lineLimit(2)
                    .minimumScaleFactor(0.6)
                if !metaLine.isEmpty {
                    Text(verbatim: metaLine)
                        .font(Theme.Typography.meta)
                        .foregroundStyle(Theme.Colors.label2)
                }
                if !card.badges.isEmpty {
                    BadgeRow(badges: card.badges)
                }
            }
            .padding(.horizontal, Theme.Layout.margin)
            .padding(.bottom, 100)
            // Same left edge as Home, which lays out against the full screen width.
            .ignoresSafeArea(edges: .horizontal)
            // Gives the page a focus target so the remote's Menu button behaves.
            .focusable()
        }
    }

    private var metaLine: String {
        var parts: [String] = []
        if let year = card.year { parts.append(String(year)) }
        if !card.subtitle.isEmpty { parts.append(card.subtitle) }
        return parts.joined(separator: " · ")
    }
}
