import Foundation

/// A song (§7.1). `id` is the track item id used for streaming, lyrics, plays and stars.
public struct Track: Codable, Hashable, Identifiable, Sendable {
    public var id: Int
    public var title: String
    public var artist: String
    public var artistId: Int
    public var albumId: Int
    public var album: String
    public var discNo: Int
    public var trackNo: Int
    public var durationMs: Int
    public var fileId: Int
    public var lossless: Bool
    public var hasLyrics: Bool
    /// Image path or `""`.
    public var cover: String
    public var starred: Bool
    /// The track is a region of a larger (CUE) file; streaming by track id handles it.
    public var cue: Bool
    /// Position within a playlist; only in playlist responses.
    public var idx: Int?

    public init(
        id: Int, title: String, artist: String = "", artistId: Int = 0, albumId: Int = 0,
        album: String = "", discNo: Int = 0, trackNo: Int = 0, durationMs: Int = 0, fileId: Int = 0,
        lossless: Bool = false, hasLyrics: Bool = false, cover: String = "", starred: Bool = false,
        cue: Bool = false, idx: Int? = nil
    ) {
        self.id = id
        self.title = title
        self.artist = artist
        self.artistId = artistId
        self.albumId = albumId
        self.album = album
        self.discNo = discNo
        self.trackNo = trackNo
        self.durationMs = durationMs
        self.fileId = fileId
        self.lossless = lossless
        self.hasLyrics = hasLyrics
        self.cover = cover
        self.starred = starred
        self.cue = cue
        self.idx = idx
    }

    enum CodingKeys: String, CodingKey {
        case id, title, artist, artistId, albumId, album, discNo, trackNo, durationMs, fileId
        case lossless, hasLyrics, cover, starred, cue, idx
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        title = c.value(.title, default: "")
        artist = c.value(.artist, default: "")
        artistId = c.value(.artistId, default: 0)
        albumId = c.value(.albumId, default: 0)
        album = c.value(.album, default: "")
        discNo = c.value(.discNo, default: 0)
        trackNo = c.value(.trackNo, default: 0)
        durationMs = c.value(.durationMs, default: 0)
        fileId = c.value(.fileId, default: 0)
        lossless = c.value(.lossless, default: false)
        hasLyrics = c.value(.hasLyrics, default: false)
        cover = c.value(.cover, default: "")
        starred = c.value(.starred, default: false)
        cue = c.value(.cue, default: false)
        idx = c.optional(.idx)
    }
}

public struct ArtistRef: Decodable, Hashable, Sendable {
    public var id: Int
    public var name: String

    enum CodingKeys: String, CodingKey { case id, name }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.value(.id, default: 0)
        name = c.value(.name, default: "")
    }
}

/// `GET /api/music/albums/{id}`.
public struct AlbumDetail: Decodable, Hashable, Sendable {
    public var card: Card
    public var artist: ArtistRef?
    public var year: Int
    public var genres: [String]
    public var durationMs: Int
    public var trackCount: Int
    /// e.g. "Lossless · FLAC".
    public var quality: String
    public var tracks: [Track]
    public var starred: Bool

    enum CodingKeys: String, CodingKey {
        case card, artist, year, genres, durationMs, trackCount, quality, tracks, starred
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        card = try c.decode(Card.self, forKey: .card)
        artist = c.optional(.artist)
        year = c.value(.year, default: 0)
        genres = c.value(.genres, default: [])
        durationMs = c.value(.durationMs, default: 0)
        trackCount = c.value(.trackCount, default: 0)
        quality = c.value(.quality, default: "")
        tracks = c.value(.tracks, default: [])
        starred = c.value(.starred, default: false)
    }
}

/// `GET /api/music/artists/{id}`.
public struct ArtistDetail: Decodable, Hashable, Sendable {
    public var card: Card
    public var albums: [Card]
    public var topTracks: [Track]
    public var appearsOn: [Card]

    enum CodingKeys: String, CodingKey { case card, albums, topTracks, appearsOn }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        card = try c.decode(Card.self, forKey: .card)
        albums = c.value(.albums, default: [])
        topTracks = c.value(.topTracks, default: [])
        appearsOn = c.value(.appearsOn, default: [])
    }
}

public struct Genre: Decodable, Hashable, Identifiable, Sendable {
    public var name: String
    public var albums: Int
    public var songs: Int

    public var id: String { name }

    enum CodingKeys: String, CodingKey { case name, albums, songs }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = c.value(.name, default: "")
        albums = c.value(.albums, default: 0)
        songs = c.value(.songs, default: 0)
    }
}

struct GenresResponse: Decodable, Sendable {
    var genres: [Genre]

    enum CodingKeys: String, CodingKey { case genres }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        genres = c.value(.genres, default: [])
    }
}

struct ShuffleResponse: Decodable, Sendable {
    var tracks: [Track]

    enum CodingKeys: String, CodingKey { case tracks }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tracks = c.value(.tracks, default: [])
    }
}

/// `GET /api/music/tracks/{id}/lyrics`.
public struct Lyrics: Decodable, Hashable, Sendable {
    /// Raw lyrics (LRC text when synced).
    public var lyrics: String
    public var synced: Bool
    /// "file" or an online lookup source.
    public var source: String
    /// Timed lines; filled when `synced`.
    public var lines: [LyricLine]

    enum CodingKeys: String, CodingKey { case lyrics, synced, source, lines }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        lyrics = c.value(.lyrics, default: "")
        synced = c.value(.synced, default: false)
        source = c.value(.source, default: "")
        lines = c.value(.lines, default: [])
    }

    /// Index of the line active at `seconds`, for synced lyrics.
    public func lineIndex(at seconds: Double) -> Int? {
        lines.lastIndex { $0.t <= seconds }
    }
}

public struct LyricLine: Decodable, Hashable, Sendable {
    /// Seconds from the start of the track.
    public var t: Double
    public var text: String

    enum CodingKeys: String, CodingKey { case t, text }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        t = c.value(.t, default: 0)
        text = c.value(.text, default: "")
    }
}

public struct Playlist: Decodable, Hashable, Identifiable, Sendable {
    public var id: Int
    public var name: String
    public var trackCount: Int
    public var durationMs: Int
    public var cover: String
    /// Up to 4 album covers for a mosaic.
    public var covers: [String]
    public var updatedAt: String

    enum CodingKeys: String, CodingKey { case id, name, trackCount, durationMs, cover, covers, updatedAt }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        name = c.value(.name, default: "")
        trackCount = c.value(.trackCount, default: 0)
        durationMs = c.value(.durationMs, default: 0)
        cover = c.value(.cover, default: "")
        covers = c.value(.covers, default: [])
        updatedAt = c.value(.updatedAt, default: "")
    }
}

/// `GET /api/music/playlists/{id}`.
public struct PlaylistDetail: Decodable, Hashable, Sendable {
    public var playlist: Playlist
    /// Tracks with `idx` set.
    public var tracks: [Track]

    enum CodingKeys: String, CodingKey { case playlist, tracks }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        playlist = try c.decode(Playlist.self, forKey: .playlist)
        tracks = c.value(.tracks, default: [])
    }
}

/// Body of `PATCH /api/music/playlists/{id}`.
public struct PlaylistUpdate: Encodable, Hashable, Sendable {
    public var name: String?
    /// Track ids to append.
    public var append: [Int]?
    /// Positions to remove.
    public var remove: [Int]?
    /// A permutation: `order[i]` is the old position placed at new position `i`.
    public var order: [Int]?

    public init(name: String? = nil, append: [Int]? = nil, remove: [Int]? = nil, order: [Int]? = nil) {
        self.name = name
        self.append = append
        self.remove = remove
        self.order = order
    }
}

struct PlaylistCreate: Encodable, Sendable {
    var name: String
    var trackIds: [Int]?
}

struct PlayRecord: Encodable, Sendable {
    var trackId: Int
    var at: String?
}

/// Sort orders of `GET /api/music/albums`.
public enum AlbumSort: String, CaseIterable, Sendable {
    /// Date added (server default).
    case added
    case title
    case artist
    case year
    case random
    /// Most played.
    case frequent
    /// Recently played.
    case recent
}

/// Source of a random queue, `GET /api/music/shuffle`.
public enum ShuffleSource: Hashable, Sendable {
    case all
    case genre(String)
    case artist(Int)

    var queryItems: [URLQueryItem] {
        switch self {
        case .all:
            return [URLQueryItem(name: "source", value: "all")]
        case .genre(let name):
            return [URLQueryItem(name: "source", value: "genre"), URLQueryItem(name: "genre", value: name)]
        case .artist(let id):
            return [URLQueryItem(name: "source", value: "artist"), URLQueryItem(name: "artist", value: String(id))]
        }
    }
}

/// Audio codecs for the `accept` parameter of track and audiobook streams (§7.3).
public enum AudioCodec: String, CaseIterable, Sendable {
    case flac, mp3, aac, alac, opus, vorbis, wav, aiff, ape, wv

    /// What AVPlayer on Apple platforms decodes natively.
    public static let apple: [AudioCodec] = [.aac, .mp3, .alac, .flac, .wav, .aiff]
}

/// Transcode targets for track and audiobook streams.
public enum AudioTranscodeFormat: String, CaseIterable, Sendable {
    case aac, mp3, opus
}

/// When a play is scrobbled: after min(30 s, duration / 2) of actually played time.
public enum ScrobblePolicy {
    public static func thresholdSeconds(durationMs: Int) -> Double {
        let half = Double(durationMs) / 2000
        return durationMs > 0 ? min(30, half) : 30
    }
}
