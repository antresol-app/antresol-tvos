import Foundation

/// The `kind` of a library entity. Unknown values from newer servers are preserved.
public struct ItemKind: RawRepresentable, Codable, Hashable, Sendable, ExpressibleByStringLiteral {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        self.rawValue = value
    }

    public static let movie: ItemKind = "movie"
    public static let series: ItemKind = "series"
    public static let season: ItemKind = "season"
    public static let episode: ItemKind = "episode"
    public static let artist: ItemKind = "artist"
    public static let album: ItemKind = "album"
    /// A playlist card. Its `id` is a playlist id, not an item id.
    public static let playlist: ItemKind = "playlist"
    public static let audiobook: ItemKind = "audiobook"
    public static let book: ItemKind = "book"
    /// A comic series.
    public static let comic: ItemKind = "comic"
    public static let comicVolume: ItemKind = "comic_volume"

    /// Movies, series, seasons and episodes: opened with `GET /api/items/{id}`.
    public var isVideo: Bool {
        [.movie, .series, .season, .episode].contains(self)
    }

    /// Books, audiobooks, comic series and volumes: opened with `GET /api/books/{id}`.
    public var isBook: Bool {
        [.book, .audiobook, .comic, .comicVolume].contains(self)
    }

    /// Artists, albums and playlists: opened through the music endpoints.
    public var isMusic: Bool {
        [.artist, .album, .playlist].contains(self)
    }
}
