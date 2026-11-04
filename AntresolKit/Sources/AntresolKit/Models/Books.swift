import Foundation

/// Kinds accepted by `GET /api/books?kind=`.
public enum BookListKind: String, CaseIterable, Sendable {
    case book
    case audiobook
    /// Comic series.
    case comic
}

/// Sort orders of `GET /api/books`.
public enum BookSort: String, CaseIterable, Sendable {
    /// Date added (server default).
    case added
    case title
    case author
}

/// Comic reading direction.
public enum ReadingDirection: String, Codable, Hashable, Sendable {
    case leftToRight = "ltr"
    case rightToLeft = "rtl"

    init(value: String) {
        self = ReadingDirection(rawValue: value) ?? .leftToRight
    }
}

/// `GET /api/books/{id}` for a book, audiobook, comic series or comic volume (§8.2).
public struct BookDetail: Decodable, Hashable, Identifiable, Sendable {
    public var card: Card
    public var kind: ItemKind
    public var authors: [String]
    public var narrator: String
    public var series: BookSeries?
    public var description: String
    public var year: Int
    public var lang: String
    /// For an audiobook: the ordered parts. Empty for a comic series.
    public var files: [BookFile]
    /// Parent comic series id for a volume, otherwise 0.
    public var seriesId: Int
    /// Next volume or book in the series, 0 if none.
    public var nextId: Int
    /// File id to open in a reader (ebook or comic volume), 0 otherwise.
    public var readFileId: Int
    public var progress: BookProgress?
    /// In the watchlist.
    public var want: Bool
    /// Audiobook total, the sum of the parts.
    public var durationMs: Int
    /// Audiobook chapters on the whole-book timeline.
    public var chapters: [Chapter]
    /// Comic series only.
    public var volumes: [VolumeCard]
    /// `""` for non-comics.
    public var direction: String

    public var id: Int { card.id }

    enum CodingKeys: String, CodingKey {
        case card, kind, authors, narrator, series, description, year, lang, files, seriesId, nextId
        case readFileId, progress, want, durationMs, chapters, volumes, direction
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        card = try c.decode(Card.self, forKey: .card)
        kind = c.value(.kind, default: card.kind)
        authors = c.value(.authors, default: [])
        narrator = c.value(.narrator, default: "")
        series = c.optional(.series)
        description = c.value(.description, default: "")
        year = c.value(.year, default: 0)
        lang = c.value(.lang, default: "")
        files = c.value(.files, default: [])
        seriesId = c.value(.seriesId, default: 0)
        nextId = c.value(.nextId, default: 0)
        readFileId = c.value(.readFileId, default: 0)
        progress = c.optional(.progress)
        want = c.value(.want, default: false)
        durationMs = c.value(.durationMs, default: 0)
        chapters = c.value(.chapters, default: [])
        volumes = c.value(.volumes, default: [])
        direction = c.value(.direction, default: "")
    }

    public var readingDirection: ReadingDirection {
        ReadingDirection(value: direction)
    }

    /// Timeline helper for the audiobook parts.
    public var audiobookTimeline: AudiobookTimeline {
        AudiobookTimeline(files: files)
    }
}

public struct BookSeries: Decodable, Hashable, Sendable {
    public var name: String
    public var index: Double

    enum CodingKeys: String, CodingKey { case name, index }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = c.value(.name, default: "")
        index = c.value(.index, default: 0)
    }
}

public struct BookFile: Decodable, Hashable, Identifiable, Sendable {
    /// File id.
    public var id: Int
    /// "M4B", "MP3", "EPUB", "CBZ"...
    public var format: String
    public var size: Int
    public var durationMs: Int

    public init(id: Int, format: String = "", size: Int = 0, durationMs: Int) {
        self.id = id
        self.format = format
        self.size = size
        self.durationMs = durationMs
    }

    enum CodingKeys: String, CodingKey { case id, format, size, durationMs }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        format = c.value(.format, default: "")
        size = c.value(.size, default: 0)
        durationMs = c.value(.durationMs, default: 0)
    }
}

public struct BookProgress: Decodable, Hashable, Sendable {
    public var fraction: Double
    public var locator: String
    public var positionMs: Int
    public var durationMs: Int
    public var finished: Bool

    public init(fraction: Double = 0, locator: String = "", positionMs: Int = 0, durationMs: Int = 0, finished: Bool = false) {
        self.fraction = fraction
        self.locator = locator
        self.positionMs = positionMs
        self.durationMs = durationMs
        self.finished = finished
    }

    enum CodingKeys: String, CodingKey { case fraction, locator, positionMs, durationMs, finished }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        fraction = c.value(.fraction, default: 0)
        locator = c.value(.locator, default: "")
        positionMs = c.value(.positionMs, default: 0)
        durationMs = c.value(.durationMs, default: 0)
        finished = c.value(.finished, default: false)
    }
}

public struct Chapter: Decodable, Hashable, Identifiable, Sendable {
    public var idx: Int
    public var title: String
    public var fileId: Int
    /// Whole-book timeline.
    public var startMs: Int
    public var endMs: Int

    public var id: Int { idx }

    enum CodingKeys: String, CodingKey { case idx, title, fileId, startMs, endMs }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        idx = c.value(.idx, default: 0)
        title = c.value(.title, default: "")
        fileId = c.value(.fileId, default: 0)
        startMs = c.value(.startMs, default: 0)
        endMs = c.value(.endMs, default: 0)
    }
}

/// A comic volume inside a series detail: Card fields plus reader info.
@dynamicMemberLookup
public struct VolumeCard: Decodable, Hashable, Identifiable, Sendable {
    public var card: Card
    public var pages: Int
    public var direction: String
    /// File id for `/api/comics/{fileId}/...`.
    public var fileId: Int

    public var id: Int { card.id }

    public subscript<T>(dynamicMember keyPath: KeyPath<Card, T>) -> T {
        card[keyPath: keyPath]
    }

    enum CodingKeys: String, CodingKey { case pages, direction, fileId }

    public init(from decoder: Decoder) throws {
        card = try Card(from: decoder)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        pages = c.value(.pages, default: 0)
        direction = c.value(.direction, default: "")
        fileId = c.value(.fileId, default: 0)
    }

    public var readingDirection: ReadingDirection {
        ReadingDirection(value: direction)
    }
}

/// `GET /api/comics/{fileId}/pages`.
public struct ComicPages: Decodable, Hashable, Sendable {
    public struct PageSize: Hashable, Sendable {
        public var width: Int
        public var height: Int
    }

    public var count: Int
    public var direction: String
    public var sizes: [PageSize]

    enum CodingKeys: String, CodingKey { case count, direction, sizes }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let raw: [[Int]] = c.value(.sizes, default: [])
        sizes = raw.map { PageSize(width: $0.first ?? 0, height: $0.dropFirst().first ?? 0) }
        count = c.value(.count, default: raw.count)
        direction = c.value(.direction, default: "")
    }

    public var readingDirection: ReadingDirection {
        ReadingDirection(value: direction)
    }
}

/// Reader progress for comic volumes (§8.5): `locator = "page:<1-based>"`.
public enum ComicProgress {
    /// The update to send after showing page `pageIndex` (0-based) of `count`.
    public static func update(pageIndex: Int, count: Int) -> ProgressUpdate {
        let fraction = count > 0 ? Double(pageIndex + 1) / Double(count) : 0
        return .reader(locator: "page:\(pageIndex + 1)", fraction: min(1, fraction))
    }

    /// The 0-based page index stored in a locator such as "page:2", or nil.
    public static func pageIndex(locator: String) -> Int? {
        guard locator.hasPrefix("page:"), let page = Int(locator.dropFirst(5)), page >= 1 else { return nil }
        return page - 1
    }
}
