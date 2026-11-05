import AntresolKit
import SwiftUI

/// Everything in a Home shelf, opened from the shelf's title. Library shelves page
/// through their full list (recently added movies and shows, recently played albums);
/// the others show what `/api/home` returns for them.
struct ShelfGridView: View {
    let shelfId: String
    let title: String

    @Environment(AppState.self) private var appState
    @State private var list = PagedList<Card>(key: \.uniqueKey)

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 48) {
                Text(verbatim: title)
                    .font(Theme.Typography.pageTitle)
                    .foregroundStyle(Theme.Colors.label)
                    .accessibilityAddTraits(.isHeader)
                    .padding(.horizontal, Theme.Layout.margin)
                CardGrid(list: list, shape: shape, emptyIcon: "square.grid.2x2", emptyTitle: "Nothing here yet")
            }
            .padding(.top, 40)
            .padding(.bottom, 100)
        }
        .scrollClipDisabled()
        .ignoresSafeArea(edges: .horizontal)
        .background(Theme.Colors.background.ignoresSafeArea())
        .task(id: shelfId) {
            let id = shelfId
            await list.reload(using: appState) { client, offset, limit in
                try await Self.page(of: id, client: client, offset: offset, limit: limit)
            }
        }
    }

    private var shape: ArtworkShape {
        shelfId == ShelfID.recentlyPlayed ? .square : .poster
    }

    private static func page(of id: String, client: APIClient, offset: Int, limit: Int) async throws -> Page<Card> {
        switch id {
        case ShelfID.recentMovies:
            return try await client.items(kind: .movie, sort: .recent, limit: limit, offset: offset)
        case ShelfID.recentSeries:
            return try await client.items(kind: .series, sort: .recent, limit: limit, offset: offset)
        case ShelfID.recentlyPlayed:
            return try await client.albums(sort: .recent, limit: limit, offset: offset)
        default:
            guard offset == 0 else { return Page(items: [], total: 0) }
            let cards = try await client.home().shelf(id)?.cards ?? []
            return Page(items: cards, total: cards.count)
        }
    }
}
