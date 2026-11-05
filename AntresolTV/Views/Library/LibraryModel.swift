import AntresolKit
import Foundation
import Observation

/// Pages through `GET /api/items` for one section (movies or series) in one sort order.
@MainActor
@Observable
final class LibraryModel {
    enum State {
        case loading
        case loaded
        case failed(String)
    }

    /// Items per request. Sixty is ten full rows of the six-column grid.
    static let pageSize = 60

    let kind: ItemKind
    private(set) var sort: ItemSort
    private(set) var state: State = .loading
    private(set) var cards: [Card] = []
    private(set) var total = 0
    private(set) var isLoadingMore = false
    private var generation = 0

    init(kind: ItemKind, sort: ItemSort) {
        self.kind = kind
        self.sort = sort
    }

    var hasMore: Bool {
        cards.count < total
    }

    /// Reloads the first page. A new sort order starts over; otherwise (the tab appearing
    /// again, a finished video) the first page is merged into the loaded cards, so later
    /// pages and the focused card stay.
    func reload(sort newSort: ItemSort, using appState: AppState) async {
        let sortChanged = newSort != sort
        sort = newSort
        generation += 1
        let current = generation
        if sortChanged || cards.isEmpty {
            state = .loading
            cards = []
            total = 0
        }
        guard let client = appState.client else { return }
        do {
            let page = try await client.items(kind: kind, sort: newSort, limit: Self.pageSize, offset: 0)
            guard current == generation else { return }
            cards = sortChanged || cards.isEmpty
                ? Self.unique(page.items)
                : PageMerge.merge(firstPage: page.items, into: cards, pageSize: Self.pageSize, key: \.uniqueKey)
            total = max(page.total, cards.count)
            state = .loaded
        } catch {
            guard current == generation, !Task.isCancelled else { return }
            let message = appState.message(for: error)
            if cards.isEmpty, let message { state = .failed(message) }
        }
    }

    /// Loads the next page when `card` is close to the end of what is loaded.
    func loadMoreIfNeeded(after card: Card, using appState: AppState) async {
        guard hasMore, !isLoadingMore, case .loaded = state,
              let index = cards.firstIndex(where: { $0.uniqueKey == card.uniqueKey }),
              index >= cards.count - 18,
              let client = appState.client
        else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        let current = generation
        do {
            let page = try await client.items(kind: kind, sort: sort, limit: Self.pageSize, offset: cards.count)
            guard current == generation else { return }
            cards = Self.unique(cards + page.items)
            total = page.items.isEmpty ? cards.count : page.total
        } catch {
            // The grid keeps what it has; scrolling to the end again retries.
            _ = appState.message(for: error)
        }
    }

    /// Drops repeated cards: items added while paging shift later pages by one.
    private static func unique(_ cards: [Card]) -> [Card] {
        var seen = Set<String>()
        return cards.filter { seen.insert($0.uniqueKey).inserted }
    }
}
