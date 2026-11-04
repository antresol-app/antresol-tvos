import AntresolKit
import Foundation
import Observation

/// What the Home tab shows, derived from `GET /api/home`.
struct HomeContent {
    struct Feature {
        let card: Card
        let eyebrow: String
    }

    /// The hero: the first featured item, else the first item to continue.
    let feature: Feature?
    /// The Continue Watching row (wide cards).
    let continueWatching: Shelf?
    /// Every other non-empty shelf, in server order (poster cards).
    let shelves: [Shelf]

    init(_ home: HomeResponse) {
        let continueShelf = home.shelf(ShelfID.continueWatching)
        if let featured = home.hero.first {
            feature = Feature(card: featured, eyebrow: Self.eyebrow(String(localized: "New in Library"), featured))
        } else if let next = continueShelf?.cards.first {
            feature = Feature(card: next, eyebrow: Self.eyebrow(String(localized: "Continue Watching"), next))
        } else {
            feature = nil
        }
        continueWatching = continueShelf.flatMap { $0.cards.isEmpty ? nil : $0 }
        shelves = home.shelves.filter { $0.id != ShelfID.continueWatching && !$0.cards.isEmpty }
    }

    var isEmpty: Bool {
        feature == nil && continueWatching == nil && shelves.isEmpty
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
            state = .loaded(HomeContent(home))
        } catch {
            guard !Task.isCancelled else { return }
            let message = appState.message(for: error)
            if case .loaded = state { return }
            if let message { state = .failed(message) }
        }
    }
}
