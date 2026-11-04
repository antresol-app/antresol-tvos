import Foundation

/// The summary object returned by almost every list in the API (§3.1).
public struct Card: Codable, Hashable, Identifiable, Sendable {
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

    public init(
        id: Int, kind: ItemKind, title: String, subtitle: String = "", year: Int? = nil,
        poster: String = "", backdrop: String = "", logo: String = "", progress: Double = 0,
        badges: [String] = [], onServer: Bool = true, seriesId: Int? = nil,
        season: Int? = nil, episode: Int? = nil, resumeSec: Double? = nil
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
    }

    enum CodingKeys: String, CodingKey {
        case id, kind, title, subtitle, year, poster, backdrop, logo, progress, badges, onServer
        case seriesId, season, episode, resumeSec
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
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

    enum CodingKeys: String, CodingKey { case hero, shelves }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hero = c.value(.hero, default: [])
        shelves = c.value(.shelves, default: [])
    }

    public func shelf(_ id: String) -> Shelf? {
        shelves.first { $0.id == id }
    }
}

/// `{shelves: [...]}` responses of `/api/music/home` and `/api/books/home`.
public struct ShelvesResponse: Decodable, Sendable {
    public var shelves: [Shelf]

    enum CodingKeys: String, CodingKey { case shelves }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        shelves = c.value(.shelves, default: [])
    }

    public func shelf(_ id: String) -> Shelf? {
        shelves.first { $0.id == id }
    }
}
