import AntresolKit
import Foundation
import Observation

/// Runs `GET /api/search` for the text in the search field, debounced while typing.
@MainActor
@Observable
final class SearchModel {
    enum State {
        /// Nothing typed: the Browse tiles show.
        case idle
        case searching
        case results([SearchGroup])
        case failed(String)
    }

    private(set) var state: State = .idle
    /// The addons' own searches, after the library's: one section per addon that found titles, in
    /// the order of the addons' ids. Empty without addons.
    private(set) var addonSections: [AddonSearchSection] = []
    /// An addon's search is still under way.
    private(set) var addonsSearching = false

    @ObservationIgnored private var generation = 0

    /// Searches for `text` after a short pause; call it from `.task(id: text)` so a new
    /// keystroke cancels the previous search. The addons that search are asked too, and their
    /// results come in as they arrive, without holding back the library's.
    func search(_ text: String, using appState: AppState, addons: AddonWays) async {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        generation += 1
        let mine = generation
        guard !query.isEmpty else {
            state = .idle
            addonSections = []
            addonsSearching = false
            return
        }
        try? await Task.sleep(nanoseconds: 300_000_000)
        guard !Task.isCancelled, let client = appState.client else { return }
        await addons.load(using: appState)
        let searches = addons.snapshot.searches
        addonSections = []
        addonsSearching = !searches.isEmpty
        let addonTask = Task { await self.searchAddons(query, searches: searches, client: client, generation: mine) }
        await withTaskCancellationHandler {
            await searchLibrary(query, using: appState, client: client)
            await addonTask.value
        } onCancel: {
            addonTask.cancel()
        }
    }

    private func searchLibrary(_ query: String, using appState: AppState, client: APIClient) async {
        if case .results = state {} else { state = .searching }
        do {
            let results = try await client.search(query)
            guard !Task.isCancelled else { return }
            state = .results(SearchGroup.groups(from: results))
        } catch {
            guard !Task.isCancelled else { return }
            if let message = appState.message(for: error) { state = .failed(message) }
        }
    }

    /// Asks each addon that searches, all at once (`AddonSearching`); whatever fails or finds nothing is
    /// left out without a word.
    private func searchAddons(_ query: String, searches: [AddonSearch], client: APIClient, generation mine: Int) async {
        for await sections in AddonSearching.sections(for: searches, ask: { try await client.addonTitles(addon: $0.addonId, query: query) }) {
            guard !Task.isCancelled, generation == mine else { break }
            addonSections = sections
        }
        if generation == mine { addonsSearching = false }
    }
}

/// One row of search results.
struct SearchGroup: Identifiable {
    /// A result card and where selecting it leads.
    struct Entry: Identifiable {
        let id: String
        let card: Card
        let destination: Card
    }

    let id: String
    let title: String
    let entries: [Entry]

    init(id: String, title: String, cards: [Card]) {
        self.id = id
        self.title = title
        self.entries = cards.map { Entry(id: $0.uniqueKey, card: $0, destination: $0) }
    }

    init(id: String, title: String, entries: [Entry]) {
        self.id = id
        self.title = title
        self.entries = entries
    }

    /// Movies, TV shows, artists, albums and songs, in that order; empty groups are left
    /// out. The server's book results are not shown: the app has no books.
    static func groups(from results: SearchResults) -> [SearchGroup] {
        let movies = results.library.filter { $0.kind == .movie }
        let shows = results.library.filter { $0.kind != .movie }
        let groups = [
            SearchGroup(id: "movies", title: String(localized: "Movies", bundle: .localized), cards: movies),
            SearchGroup(id: "shows", title: String(localized: "Shows", bundle: .localized), cards: shows),
            SearchGroup(id: "artists", title: String(localized: "Artists", bundle: .localized), cards: results.artists),
            SearchGroup(id: "albums", title: String(localized: "Albums", bundle: .localized), cards: results.albums),
            SearchGroup(id: "songs", title: String(localized: "Songs", bundle: .localized), entries: results.songs.map(Self.entry(for:))),
        ]
        return groups.filter { !$0.entries.isEmpty }
    }

    /// A song shows its title with the artist and album under the album cover, and opens
    /// its album.
    private static func entry(for track: Track) -> Entry {
        let context = [track.artist, track.album].filter { !$0.isEmpty }.joined(separator: " · ")
        return Entry(
            id: "track-\(track.id)",
            card: Card(id: track.id, kind: .album, title: track.title, subtitle: context, poster: track.cover),
            destination: Card(id: track.albumId, kind: .album, title: track.album, subtitle: track.artist, poster: track.cover)
        )
    }
}
