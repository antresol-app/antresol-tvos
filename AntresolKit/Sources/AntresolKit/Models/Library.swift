import Foundation

/// `GET /api/items/{id}` for a movie, series, season or episode (§4.3).
/// The card fields are flattened at the top level of the JSON; they are exposed
/// through `card` and, for convenience, through dynamic member lookup.
@dynamicMemberLookup
public struct ItemDetail: Decodable, Hashable, Identifiable, Sendable {
    public var card: Card
    public var originalTitle: String?
    public var overview: String
    public var genres: [String]
    /// Minutes.
    public var runtime: Int?
    /// Age rating, e.g. "16+".
    public var rating: String?
    public var cast: [CastMember]
    /// All seasons of a series, or only the requested season.
    public var seasons: [SeasonInfo]
    /// Playable files of a movie or episode. Several files are alternative versions.
    public var files: [FileInfo]
    /// Series only: the episode to play next.
    public var next: EpisodeCard?
    public var inWatchlist: Bool
    public var actions: ItemActions
    public var tmdbId: Int?

    public var id: Int { card.id }

    public subscript<T>(dynamicMember keyPath: KeyPath<Card, T>) -> T {
        card[keyPath: keyPath]
    }

    enum CodingKeys: String, CodingKey {
        case originalTitle, overview, genres, runtime, rating, cast, seasons, files, next
        case inWatchlist, actions, tmdbId
    }

    public init(from decoder: Decoder) throws {
        card = try Card(from: decoder)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        originalTitle = c.optional(.originalTitle)
        overview = c.value(.overview, default: "")
        genres = c.value(.genres, default: [])
        runtime = c.optional(.runtime)
        rating = c.optional(.rating)
        cast = c.value(.cast, default: [])
        seasons = c.value(.seasons, default: [])
        files = c.value(.files, default: [])
        next = c.optional(.next)
        inWatchlist = c.value(.inWatchlist, default: false)
        actions = c.value(.actions, default: ItemActions())
        tmdbId = c.optional(.tmdbId)
    }

    /// The default file to play (the first version).
    public var primaryFile: FileInfo? {
        files.first
    }
}

public struct CastMember: Decodable, Hashable, Sendable {
    public var name: String
    public var character: String?

    enum CodingKeys: String, CodingKey { case name, character }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = c.value(.name, default: "")
        character = c.optional(.character)
    }
}

public struct ItemActions: Decodable, Hashable, Sendable {
    /// Something is playable.
    public var play: Bool
    public var toServer: Bool
    /// An offline copy is possible.
    public var toDevice: Bool
    public var watchNow: Bool

    public init(play: Bool = false, toServer: Bool = false, toDevice: Bool = false, watchNow: Bool = false) {
        self.play = play
        self.toServer = toServer
        self.toDevice = toDevice
        self.watchNow = watchNow
    }

    enum CodingKeys: String, CodingKey { case play, toServer, toDevice, watchNow }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        play = c.value(.play, default: false)
        toServer = c.value(.toServer, default: false)
        toDevice = c.value(.toDevice, default: false)
        watchNow = c.value(.watchNow, default: false)
    }
}

public struct SeasonInfo: Decodable, Hashable, Identifiable, Sendable {
    public var id: Int
    public var number: Int
    public var title: String
    public var episodes: [EpisodeCard]

    enum CodingKeys: String, CodingKey { case id, number, title, episodes }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        number = c.value(.number, default: 0)
        title = c.value(.title, default: "")
        episodes = c.value(.episodes, default: [])
    }
}

/// A Card with episode fields. It carries no file id: fetch the episode's
/// `ItemDetail` to play it.
@dynamicMemberLookup
public struct EpisodeCard: Decodable, Hashable, Identifiable, Sendable {
    public var card: Card
    public var seasonNo: Int
    public var episodeNo: Int
    public var overview: String?
    public var durationMs: Int?
    public var watched: Bool

    public var id: Int { card.id }

    public subscript<T>(dynamicMember keyPath: KeyPath<Card, T>) -> T {
        card[keyPath: keyPath]
    }

    enum CodingKeys: String, CodingKey { case seasonNo, episodeNo, overview, durationMs, watched }

    public init(from decoder: Decoder) throws {
        card = try Card(from: decoder)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        seasonNo = c.value(.seasonNo, default: 0)
        episodeNo = c.value(.episodeNo, default: 0)
        overview = c.optional(.overview)
        durationMs = c.optional(.durationMs)
        watched = c.value(.watched, default: false)
    }
}

/// A physical media file of a movie or episode.
public struct FileInfo: Decodable, Hashable, Identifiable, Sendable {
    /// File id, used with `/api/play/{fileId}`.
    public var id: Int
    public var name: String
    public var size: Int
    public var durationMs: Int?
    /// "720p", "1080p", "4K"...
    public var resolution: String?
    public var audio: [AudioTrack]
    public var subs: [SubtitleTrack]

    enum CodingKeys: String, CodingKey { case id, name, size, durationMs, resolution, audio, subs }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        name = c.value(.name, default: "")
        size = c.value(.size, default: 0)
        durationMs = c.optional(.durationMs)
        resolution = c.optional(.resolution)
        audio = c.value(.audio, default: [])
        subs = c.value(.subs, default: [])
    }
}

public struct AudioTrack: Decodable, Hashable, Identifiable, Sendable {
    /// ffprobe stream index; pass it as `audioIndex` to `/api/play`.
    public var index: Int
    public var codec: String
    /// ISO 639-2 code, or `""` / `"und"` when unknown.
    public var lang: String
    public var title: String
    public var channels: Int
    public var isDefault: Bool

    public var id: Int { index }

    enum CodingKeys: String, CodingKey {
        case index, codec, lang, title, channels
        case isDefault = "default"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        index = try c.decode(Int.self, forKey: .index)
        codec = c.value(.codec, default: "")
        lang = c.value(.lang, default: "")
        title = c.value(.title, default: "")
        channels = c.value(.channels, default: 0)
        isDefault = c.value(.isDefault, default: false)
    }

    /// The language code, or nil when unknown.
    public var language: String? {
        LanguageCode.known(lang)
    }
}

public struct SubtitleTrack: Decodable, Hashable, Identifiable, Sendable {
    /// Stream index for embedded tracks; external sidecar files use 1000+.
    public var index: Int
    public var codec: String
    public var lang: String
    public var title: String
    public var forced: Bool
    public var isDefault: Bool
    public var external: Bool
    /// Image subtitles that can only be burned in (`burnSubtitle` in `/api/play`).
    public var burnIn: Bool
    /// Server-relative WebVTT path; present for text subtitles only.
    public var url: String?

    public var id: Int { index }

    enum CodingKeys: String, CodingKey {
        case index, codec, lang, title, forced, external, burnIn, url
        case isDefault = "default"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        index = try c.decode(Int.self, forKey: .index)
        codec = c.value(.codec, default: "")
        lang = c.value(.lang, default: "")
        title = c.value(.title, default: "")
        forced = c.value(.forced, default: false)
        isDefault = c.value(.isDefault, default: false)
        external = c.value(.external, default: false)
        burnIn = c.value(.burnIn, default: false)
        url = c.optional(.url)
    }

    public var language: String? {
        LanguageCode.known(lang)
    }

    /// Whether the track can be fetched as WebVTT and side-loaded.
    public var isText: Bool {
        !burnIn && (url?.isEmpty == false)
    }
}

/// Track language helpers.
public enum LanguageCode {
    /// Returns the code unless it is empty or "und".
    public static func known(_ code: String) -> String? {
        let trimmed = code.trimmingCharacters(in: .whitespaces).lowercased()
        return trimmed.isEmpty || trimmed == "und" ? nil : trimmed
    }
}

/// `GET /api/search?q=`.
public struct SearchResults: Decodable, Sendable {
    /// Movies and series.
    public var library: [Card]
    public var albums: [Card]
    public var artists: [Card]
    public var songs: [Track]
    public var audiobooks: [Card]
    public var books: [Card]
    public var comics: [Card]

    enum CodingKeys: String, CodingKey { case library, albums, artists, songs, audiobooks, books, comics }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        library = c.value(.library, default: [])
        albums = c.value(.albums, default: [])
        artists = c.value(.artists, default: [])
        songs = c.value(.songs, default: [])
        audiobooks = c.value(.audiobooks, default: [])
        books = c.value(.books, default: [])
        comics = c.value(.comics, default: [])
    }

    public var isEmpty: Bool {
        library.isEmpty && albums.isEmpty && artists.isEmpty && songs.isEmpty
            && audiobooks.isEmpty && books.isEmpty && comics.isEmpty
    }
}

/// Sort orders of `GET /api/items`.
public enum ItemSort: String, CaseIterable, Sendable {
    /// Date added, newest first (server default).
    case recent
    case title
    /// Newest first.
    case year
}
