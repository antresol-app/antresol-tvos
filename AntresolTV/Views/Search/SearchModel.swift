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

    /// Searches for `text` after a short pause; call it from `.task(id: text)` so a new
    /// keystroke cancels the previous search.
    func search(_ text: String, using appState: AppState) async {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            state = .idle
            return
        }
        try? await Task.sleep(nanoseconds: 300_000_000)
        guard !Task.isCancelled, let client = appState.client else { return }
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

    /// Movies, TV shows, artists, albums, songs, audiobooks, books and comics, in that
    /// order; empty groups are left out.
    static func groups(from results: SearchResults) -> [SearchGroup] {
        let movies = results.library.filter { $0.kind == .movie }
        let shows = results.library.filter { $0.kind != .movie }
        let groups = [
            SearchGroup(id: "movies", title: String(localized: "Movies"), cards: movies),
            SearchGroup(id: "shows", title: String(localized: "TV Shows"), cards: shows),
            SearchGroup(id: "artists", title: String(localized: "Artists"), cards: results.artists),
            SearchGroup(id: "albums", title: String(localized: "Albums"), cards: results.albums),
            SearchGroup(id: "songs", title: String(localized: "Songs"), entries: results.songs.map(Self.entry(for:))),
            SearchGroup(id: "audiobooks", title: String(localized: "Audiobooks"), cards: results.audiobooks),
            SearchGroup(id: "books", title: String(localized: "Books"), cards: results.books),
            SearchGroup(id: "comics", title: String(localized: "Comics"), cards: results.comics),
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
