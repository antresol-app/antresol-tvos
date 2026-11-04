import AntresolKit
import SwiftUI

/// The detail route for a card. This milestone shows the artwork-tinted header, title,
/// meta line and, for movies and shows, the overview and genres; seasons, cast, versions
/// and playback come with the full detail page (see NOTES.md).
struct ItemDetailView: View {
    let card: Card

    @Environment(AppState.self) private var appState
    @State private var detail: ItemDetail?

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
                if let overview = detail?.overview, !overview.isEmpty {
                    Text(verbatim: overview)
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.Colors.label)
                        .lineLimit(6)
                        .frame(maxWidth: 1100, alignment: .leading)
                        .padding(.top, 8)
                }
            }
            .padding(.horizontal, Theme.Layout.margin)
            .padding(.bottom, 100)
            // Same left edge as Home, which lays out against the full screen width.
            .ignoresSafeArea(edges: .horizontal)
            // Gives the page a focus target so the remote's Menu button and scrolling behave.
            .focusable()
        }
        .task(id: card.uniqueKey) { await load() }
    }

    private var metaLine: String {
        var parts: [String] = []
        if let year = card.year { parts.append(String(year)) }
        if !card.subtitle.isEmpty { parts.append(card.subtitle) }
        if let detail {
            if let runtime = detail.runtime, runtime > 0 {
                parts.append(String(localized: "\(runtime) min"))
            }
            if let rating = detail.rating, !rating.isEmpty { parts.append(rating) }
            parts.append(contentsOf: detail.genres.prefix(3))
        }
        return parts.joined(separator: " · ")
    }

    private func load() async {
        guard card.kind.isVideo, let client = appState.client else { return }
        do {
            detail = try await client.item(id: card.id)
        } catch {
            // The header already shows the card; a failed detail load only drops the overview.
            if !Task.isCancelled { _ = appState.message(for: error) }
        }
    }
}
