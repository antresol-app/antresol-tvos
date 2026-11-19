import Foundation

/// The summary object returned by almost every list in the API (§3.1).
public struct Card: Codable, Hashable, Identifiable, Sendable {
    /// The library item's id. 0 is a title off the library (a TMDB card of «New Releases»; a card
    /// without an id reads as one): no page can open it, and `Shelf.openable` leaves it out.
    public var id: Int
    public var kind: ItemKind
    public var title: String
    /// Context line, e.g. the artist of an album or "Show · Season 1, Episode 1".
    public var subtitle: String
    public var year: Int?
    /// Server-relative image path, or `""` when there is none.
    public var poster: String
    public var backdrop: String
    public var logo: String
    /// Watched or read fraction, 0...1.
    public var progress: Double
    /// Localized display-only labels such as "1080p" or "Audio EN RU".
    public var badges: [String]
    public var onServer: Bool
    /// Parent series id for episode, season and comic volume cards.
    public var seriesId: Int?
    public var season: Int?
    public var episode: Int?
    public var resumeSec: Double?
    /// The profile finished it: a movie or episode was watched to the end, a series or
    /// season has every episode in the library watched. The server omits it when false.
    public var watched: Bool
    /// Episode cards only: a 16:9 still of this episode (its own stored still, else a frame
    /// of its video), or `""`. Episode tiles show it before the series' backdrop or poster.
    public var thumb: String

    public init(
        id: Int, kind: ItemKind, title: String, subtitle: String = "", year: Int? = nil,
        poster: String = "", backdrop: String = "", logo: String = "", progress: Double = 0,
        badges: [String] = [], onServer: Bool = true, seriesId: Int? = nil,
        season: Int? = nil, episode: Int? = nil, resumeSec: Double? = nil,
        watched: Bool = false, thumb: String = ""
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.year = year
        self.poster = poster
        self.backdrop = backdrop
        self.logo = logo
        self.progress = progress
        self.badges = badges
        self.onServer = onServer
        self.seriesId = seriesId
        self.season = season
        self.episode = episode
        self.resumeSec = resumeSec
        self.watched = watched
        self.thumb = thumb
    }

    enum CodingKeys: String, CodingKey {
        case id, kind, title, subtitle, year, poster, backdrop, logo, progress, badges, onServer
        case seriesId, season, episode, resumeSec, watched, thumb
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // A card the server sent without an id is one off the library, not a reason to fail the response.
        id = c.value(.id, default: 0)
        kind = c.value(.kind, default: ItemKind(rawValue: ""))
        title = c.value(.title, default: "")
        subtitle = c.value(.subtitle, default: "")
        year = c.optional(.year)
        poster = c.value(.poster, default: "")
        backdrop = c.value(.backdrop, default: "")
        logo = c.value(.logo, default: "")
        progress = c.value(.progress, default: 0)
        badges = c.value(.badges, default: [])
        onServer = c.value(.onServer, default: true)
        seriesId = c.optional(.seriesId)
        season = c.optional(.season)
        episode = c.optional(.episode)
        resumeSec = c.optional(.resumeSec)
        watched = c.value(.watched, default: false)
        thumb = c.value(.thumb, default: "")
    }

    /// Artwork for a 16:9 episode tile, best first: the episode's own still, then the
    /// backdrop and the poster (empty paths are skipped by the views).
    public var wideArtwork: [String] {
        [thumb, backdrop, poster]
    }

    /// A key that is unique across kinds (playlist ids live in their own id space).
    public var uniqueKey: String {
        "\(kind.rawValue)-\(id)"
    }
}

/// A titled row of cards, used by `/api/home`, `/api/music/home` and `/api/books/home`.
public struct Shelf: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var cards: [Card]

    public init(id: String, title: String, cards: [Card]) {
        self.id = id
        self.title = title
        self.cards = cards
    }

    enum CodingKeys: String, CodingKey { case id, title, cards }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.value(.id, default: "")
        title = c.value(.title, default: "")
        cards = c.value(.cards, default: [])
    }

    /// The cards the app can show: library items, each once. «New Releases» (`tracked-new`) also
    /// lists followed titles that are not in the library as TMDB cards with id 0, which no page can
    /// open (`/api/items/0`) and which share kind and id: a row keyed by them would hold one
    /// identity several times, which SwiftUI treats as undefined.
    public var openable: Shelf {
        let kept = cards.openable
        return kept.count == cards.count ? self : Shelf(id: id, title: title, cards: kept)
    }
}

extension Array where Element == Card {
    /// The cards with a library id, the first of each kind and id.
    var openable: [Card] {
        var seen = Set<String>()
        return filter { $0.id > 0 && seen.insert($0.uniqueKey).inserted }
    }
}

extension Array where Element == Shelf {
    /// Every shelf's `openable` cards, without the shelves left with none.
    var openable: [Shelf] {
        compactMap { shelf in
            let kept = shelf.openable
            return kept.cards.isEmpty ? nil : kept
        }
    }
}

/// Well-known shelf ids.
public enum ShelfID {
    public static let continueWatching = "continue"
    public static let recentlyPlayed = "recently-played"
    public static let reading = "reading"
    public static let recentMovies = "recent-movies"
    public static let recentSeries = "recent-series"
    public static let watchlist = "watchlist"
    public static let recentAlbums = "recent-albums"
    public static let artists = "artists"
    public static let playlists = "playlists"
    public static let want = "want"
    public static let audiobooks = "audiobooks"
    public static let books = "books"
    public static let comics = "comics"
    public static let done = "done"
}

/// `{items: [T], total}` list responses.
public struct Page<Element: Decodable & Sendable>: Decodable, Sendable {
    public var items: [Element]
    public var total: Int

    public init(items: [Element], total: Int) {
        self.items = items
        self.total = total
    }

    enum CodingKeys: String, CodingKey { case items, total }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        items = c.value(.items, default: [])
        total = c.value(.total, default: items.count)
    }

    /// Whether another page exists after one requested at `offset`.
    public func hasMore(after offset: Int) -> Bool {
        offset + items.count < total
    }
}

/// `GET /api/home`.
public struct HomeResponse: Decodable, Sendable {
    public var hero: [Card]
    public var shelves: [Shelf]

    public init(hero: [Card], shelves: [Shelf]) {
        self.hero = hero
        self.shelves = shelves
    }

    enum CodingKeys: String, CodingKey { case hero, shelves }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hero = c.value(.hero, default: [])
        shelves = c.value(.shelves, default: [])
    }

    public func shelf(_ id: String) -> Shelf? {
        shelves.first { $0.id == id }
    }

    /// What the app shows: `Shelf.openable` hero and shelves.
    public var openable: HomeResponse {
        HomeResponse(hero: hero.openable, shelves: shelves.openable)
    }

    /// Home without books, audiobooks and comics, which the TV app does not offer: their
    /// cards leave the hero and every shelf, and shelves left empty are dropped.
    public var withoutBooks: HomeResponse {
        HomeResponse(
            hero: hero.filter { !$0.kind.isBook },
            shelves: shelves.compactMap { shelf in
                let cards = shelf.cards.filter { !$0.kind.isBook }
                return cards.isEmpty ? nil : Shelf(id: shelf.id, title: shelf.title, cards: cards)
            }
        )
    }
}

/// `{shelves: [...]}` responses of `/api/music/home` and `/api/books/home`.
public struct ShelvesResponse: Decodable, Sendable {
    public var shelves: [Shelf]

    public init(shelves: [Shelf]) {
        self.shelves = shelves
    }

    enum CodingKeys: String, CodingKey { case shelves }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        shelves = c.value(.shelves, default: [])
    }

    public func shelf(_ id: String) -> Shelf? {
        shelves.first { $0.id == id }
    }

    /// What the app shows: `Shelf.openable` shelves.
    public var openable: ShelvesResponse {
        ShelvesResponse(shelves: shelves.openable)
    }
}
