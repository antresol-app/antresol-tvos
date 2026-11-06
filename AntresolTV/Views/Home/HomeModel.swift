import AntresolKit
import Foundation
import Observation

/// What the Home tab shows, derived from `GET /api/home` without its books.
struct HomeContent {
    struct Feature: Hashable {
        let card: Card
        let eyebrow: String
    }

    /// The hero carousel: the featured items, else the first item to continue.
    let features: [Feature]
    /// The Continue Watching row (wide cards).
    let continueWatching: Shelf?
    /// Every other non-empty shelf, in server order (poster cards).
    let shelves: [Shelf]

    init(_ home: HomeResponse) {
        let continueShelf = home.shelf(ShelfID.continueWatching)
        if !home.hero.isEmpty {
            let lead = String(localized: "New in Library", bundle: .localized)
            var seen = Set<String>()
            features = home.hero
                .filter { seen.insert($0.uniqueKey).inserted }
                .map { Feature(card: $0, eyebrow: Self.eyebrow(lead, $0)) }
        } else if let next = continueShelf?.cards.first {
            features = [Feature(card: next, eyebrow: Self.eyebrow(String(localized: "Continue Watching", bundle: .localized), next))]
        } else {
            features = []
        }
        continueWatching = continueShelf.flatMap { $0.cards.isEmpty ? nil : $0 }
        shelves = home.shelves.filter { $0.id != ShelfID.continueWatching && !$0.cards.isEmpty }
    }

    var isEmpty: Bool {
        features.isEmpty && continueWatching == nil && shelves.isEmpty
    }

    private static func eyebrow(_ lead: String, _ card: Card) -> String {
        let kind = card.kind.displayName
        return kind.isEmpty ? lead : "\(lead) · \(kind)"
    }
}

/// Loads and refreshes the Home tab.
@MainActor
@Observable
final class HomeModel {
    enum State {
        case loading
        case loaded(HomeContent)
        case failed(String)
    }

    private(set) var state: State = .loading

    /// Loads Home, or refreshes it in place when it is already showing (e.g. when coming
    /// back from a detail page, so Continue Watching reflects new progress).
    func load(using appState: AppState) async {
        guard let client = appState.client else { return }
        if case .failed = state { state = .loading }
        do {
            let home = try await client.home()
            state = .loaded(HomeContent(home.withoutBooks))
        } catch {
            guard !Task.isCancelled else { return }
            let message = appState.message(for: error)
            if case .loaded = state { return }
            if let message { state = .failed(message) }
        }
    }
}
