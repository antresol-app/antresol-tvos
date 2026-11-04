import AntresolKit
import Foundation
import Observation

/// Loads one value for a page (album, artist, book...) and keeps it while refreshing.
@MainActor
@Observable
final class ContentLoader<Value> {
    enum State {
        case loading
        case loaded(Value)
        case failed(String)
    }

    private(set) var state: State = .loading

    var value: Value? {
        if case .loaded(let value) = state { return value }
        return nil
    }

    /// Loads, or refreshes in place when a value is already showing (a failed refresh
    /// keeps the old value). A `401` signs out to the profile picker.
    func load(using appState: AppState, _ fetch: @escaping (APIClient) async throws -> Value) async {
        guard let client = appState.client else { return }
        if case .failed = state { state = .loading }
        do {
            let value = try await fetch(client)
            state = .loaded(value)
        } catch {
            guard !Task.isCancelled else { return }
            let message = appState.message(for: error)
            if case .loaded = state { return }
            if let message { state = .failed(message) }
        }
    }

    /// Replaces the shown value after a local change (a star, a watchlist toggle).
    func update(_ transform: (inout Value) -> Void) {
        guard case .loaded(var value) = state else { return }
        transform(&value)
        state = .loaded(value)
    }
}

/// Pages through a list endpoint (`{items, total}`), loading the next page as the
/// user nears the end of what is loaded.
@MainActor
@Observable
final class PagedList<Element: Decodable & Sendable> {
    typealias Fetch = (APIClient, _ offset: Int, _ limit: Int) async throws -> Page<Element>

    enum State {
        case loading
        case loaded
        case failed(String)
    }

    private(set) var state: State = .loading
    private(set) var items: [Element] = []
    private(set) var total = 0
    private(set) var isLoadingMore = false

    let pageSize: Int
    private let key: (Element) -> String
    private var fetch: Fetch?
    private var generation = 0

    init(pageSize: Int = 60, key: @escaping (Element) -> String) {
        self.pageSize = pageSize
        self.key = key
    }

    var hasMore: Bool { items.count < total }

    /// Loads the first page with `fetch`. With `reset` the list empties first (a new
    /// sort order); otherwise the current items stay until the new page arrives.
    func reload(using appState: AppState, reset: Bool = false, _ fetch: @escaping Fetch) async {
        self.fetch = fetch
        generation += 1
        let current = generation
        if reset || items.isEmpty {
            state = .loading
            items = []
            total = 0
        }
        guard let client = appState.client else { return }
        do {
            let page = try await fetch(client, 0, pageSize)
            guard current == generation else { return }
            items = unique(page.items)
            total = max(page.total, items.count)
            state = .loaded
        } catch {
            guard current == generation, !Task.isCancelled else { return }
            let message = appState.message(for: error)
            if items.isEmpty, let message { state = .failed(message) }
        }
    }

    /// Loads the first page again with the last fetch (Try Again).
    func reloadSameFetch(using appState: AppState) async {
        guard let fetch else { return }
        await reload(using: appState, fetch)
    }

    /// Loads the next page when `element` is within the last `threshold` items.
    func loadMoreIfNeeded(after element: Element, threshold: Int = 18, using appState: AppState) async {
        guard hasMore, !isLoadingMore, case .loaded = state, let fetch, let client = appState.client else { return }
        let id = key(element)
        guard let index = items.firstIndex(where: { key($0) == id }), index >= items.count - threshold else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        let current = generation
        do {
            let page = try await fetch(client, items.count, pageSize)
            guard current == generation else { return }
            items = unique(items + page.items)
            total = page.items.isEmpty ? items.count : max(page.total, items.count)
        } catch {
            // Keep what is loaded; reaching the end again retries.
            _ = appState.message(for: error)
        }
    }

    /// Drops repeated elements: items added while paging shift later pages.
    private func unique(_ elements: [Element]) -> [Element] {
        var seen = Set<String>()
        return elements.filter { seen.insert(key($0)).inserted }
    }
}
