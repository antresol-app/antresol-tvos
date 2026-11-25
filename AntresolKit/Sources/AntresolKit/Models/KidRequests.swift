import Foundation

// A kid profile asks a parent for what the library lacks (the server's `/api/requests…`, the
// web's «Попросить»): `GET /api/requests/search` finds the titles a kid may ask for, `POST
// /api/requests` asks, `GET /api/requests/mine` lists what the profile asked and what was answered.

/// A kid's request and where it stands.
public struct KidRequest: Decodable, Hashable, Identifiable, Sendable {
    /// `inLibrary` is derived by the server: the library has the title now.
    public enum Status: String, Hashable, Sendable {
        case pending, approved, declined
        case inLibrary = "in_library"
    }

    public var id: Int
    /// Names the title (`tmdb:603`, `ext:…`, `name:…`): one request per kid and key.
    public var key: String
    /// `movie`, `series`, `music`, `book`, `audiobook`, `comic`.
    public var kind: String
    public var tmdbId: Int
    public var title: String
    /// The artist or the author.
    public var subtitle: String
    public var year: Int?
    /// Movies and series only: albums and books come without a cover.
    public var poster: String
    public var status: Status
    /// Why a parent declined ("": not said).
    public var reason: String
    public var libraryItemId: Int?
    public var createdAt: Date?
    /// The title is above the profile's age limit now: no title or cover.
    public var hidden: Bool

    public init(
        id: Int, key: String, kind: String, tmdbId: Int = 0, title: String, subtitle: String = "", year: Int? = nil,
        poster: String = "", status: Status = .pending, reason: String = "", libraryItemId: Int? = nil,
        createdAt: Date? = nil, hidden: Bool = false
    ) {
        self.id = id
        self.key = key
        self.kind = kind
        self.tmdbId = tmdbId
        self.title = title
        self.subtitle = subtitle
        self.year = year
        self.poster = poster
        self.status = status
        self.reason = reason
        self.libraryItemId = libraryItemId
        self.createdAt = createdAt
        self.hidden = hidden
    }

    enum CodingKeys: String, CodingKey {
        case id, key, kind, tmdbId, title, subtitle, year, poster, status, reason, libraryItemId, createdAt, hidden
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        key = try c.decode(String.self, forKey: .key)
        kind = try c.decode(String.self, forKey: .kind)
        tmdbId = c.value(.tmdbId, default: 0)
        title = c.value(.title, default: "")
        subtitle = c.value(.subtitle, default: "")
        let listedYear: Int? = c.optional(.year)
        year = listedYear.flatMap { $0 > 0 ? $0 : nil }
        poster = c.value(.poster, default: "")
        // A status this app does not know is a question still open.
        let named: String = c.value(.status, default: "")
        status = Status(rawValue: named) ?? .pending
        reason = c.value(.reason, default: "")
        let item: Int? = c.optional(.libraryItemId)
        libraryItemId = item.flatMap { $0 > 0 ? $0 : nil }
        let stamp: String? = c.optional(.createdAt)
        createdAt = Timestamp.parse(stamp)
        hidden = c.value(.hidden, default: false)
    }

    /// A movie or series has a page of its own (the title's); an album or a book has none.
    public var isVideo: Bool { kind == "movie" || kind == "series" }

    /// The slot the request is kept under: kind and the server's key.
    public var slot: String { RequestState.slot(kind: kind, key: key) }
}

/// The `kidRequest` field of a kid's search result and title page: the title's key, whether it
/// may be asked for (`blocked`: why not, in the profile's language) and the profile's request of
/// it (nil: none yet).
public struct RequestState: Decodable, Hashable, Sendable {
    public var key: String
    public var allowed: Bool
    public var blocked: String?
    public var request: KidRequest?

    public init(key: String, allowed: Bool = true, blocked: String? = nil, request: KidRequest? = nil) {
        self.key = key
        self.allowed = allowed
        self.blocked = blocked
        self.request = request
    }

    enum CodingKeys: String, CodingKey { case key, allowed, blocked, request }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = try c.decode(String.self, forKey: .key)
        allowed = c.value(.allowed, default: true)
        let why: String? = c.optional(.blocked)
        blocked = why.flatMap { $0.isEmpty ? nil : $0 }
        request = c.optional(.request)
    }

    /// Kind and key as one string: what the app keeps a profile's requests by.
    public static func slot(kind: String, key: String) -> String { kind + "|" + key }
}

/// What `GET /api/requests/search?kind=` searches: movies and series (`video`, TMDB), or the
/// catalogue of one more kind.
public enum RequestSearchKind: String, Hashable, Sendable, CaseIterable {
    case video, music, book, audiobook, comic
}

/// A title a kid may ask for, with where its request stands.
public struct KidCandidate: Decodable, Hashable, Identifiable, Sendable {
    public var kind: String
    public var tmdbId: Int
    /// The catalogue's id (albums, books).
    public var extId: String
    public var title: String
    public var subtitle: String
    public var year: Int?
    /// Movies and series only.
    public var poster: String
    public var aliases: [String]
    public var kidRequest: RequestState?

    public var id: String { [kind, String(tmdbId), extId, title].joined(separator: "|") }

    public init(
        kind: String, tmdbId: Int = 0, extId: String = "", title: String, subtitle: String = "", year: Int? = nil,
        poster: String = "", aliases: [String] = [], kidRequest: RequestState? = nil
    ) {
        self.kind = kind
        self.tmdbId = tmdbId
        self.extId = extId
        self.title = title
        self.subtitle = subtitle
        self.year = year
        self.poster = poster
        self.aliases = aliases
        self.kidRequest = kidRequest
    }

    enum CodingKeys: String, CodingKey { case kind, tmdbId, extId, title, subtitle, year, poster, aliases, kidRequest }

    /// A result without a kind or a name does not decode (the list drops it).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(String.self, forKey: .kind)
        title = try c.decode(String.self, forKey: .title).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !kind.isEmpty, !title.isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: .title, in: c, debugDescription: "not a title")
        }
        tmdbId = c.value(.tmdbId, default: 0)
        extId = c.value(.extId, default: "")
        subtitle = c.value(.subtitle, default: "")
        let listedYear: Int? = c.optional(.year)
        year = listedYear.flatMap { $0 > 0 ? $0 : nil }
        poster = c.value(.poster, default: "")
        aliases = c.value(.aliases, default: [])
        kidRequest = c.optional(.kidRequest)
    }

    public var isVideo: Bool { kind == "movie" || kind == "series" }

    /// The request this result makes when asked for.
    public var ask: KidRequestAsk {
        isVideo
            ? KidRequestAsk(kind: kind, tmdbId: tmdbId, title: title)
            : KidRequestAsk(kind: kind, extId: extId, title: title, subtitle: kind == "comic" ? nil : subtitle, year: year, aliases: aliases)
    }
}

/// The body of `POST /api/requests`: a TMDB title by its id, an album or a book as the
/// catalogue showed it. What a title does not need is left out.
public struct KidRequestAsk: Encodable, Hashable, Sendable {
    public var kind: String
    public var tmdbId: Int?
    public var extId: String?
    public var title: String
    public var subtitle: String?
    public var year: Int?
    public var aliases: [String]?

    public init(kind: String, tmdbId: Int? = nil, extId: String? = nil, title: String, subtitle: String? = nil, year: Int? = nil, aliases: [String]? = nil) {
        self.kind = kind
        self.tmdbId = tmdbId
        self.extId = extId.flatMap { $0.isEmpty ? nil : $0 }
        self.title = title
        self.subtitle = subtitle.flatMap { $0.isEmpty ? nil : $0 }
        self.year = year
        self.aliases = aliases.flatMap { $0.isEmpty ? nil : $0 }
    }
}

/// A kid profile's requests by slot, newest first, and the rules of the search section: what is
/// shown for a title, which kinds a search asks, how the answers are put together. Plain values,
/// so the screens' logic is testable without a screen.
public struct KidRequestBook: Equatable, Sendable {
    public private(set) var mine: [String: KidRequest] = [:]
    /// The slots the server refused (above the profile's age limit), with its words.
    public private(set) var blocked: [String: String] = [:]

    public init() {}

    /// Newest first.
    public var list: [KidRequest] {
        mine.values.sorted { ($0.createdAt ?? .distantPast, $0.id) > ($1.createdAt ?? .distantPast, $1.id) }
    }

    /// The profile's request of a title: what the book knows now, else what the page came with.
    public func request(kind: String, state: RequestState?) -> KidRequest? {
        guard let state else { return nil }
        return mine[RequestState.slot(kind: kind, key: state.key)] ?? state.request
    }

    /// Why the title cannot be asked for: the server said so while asking, or with the state.
    public func blockedReason(kind: String, state: RequestState?) -> String? {
        guard let state else { return nil }
        return blocked[RequestState.slot(kind: kind, key: state.key)] ?? (state.allowed ? nil : state.blocked)
    }

    /// The server's list replaces what the book had.
    public mutating func replace(with list: [KidRequest]) {
        mine = Dictionary(list.map { ($0.slot, $0) }, uniquingKeysWith: { first, _ in first })
    }

    public mutating func put(_ request: KidRequest) {
        mine[request.slot] = request
        blocked[request.slot] = nil
    }

    public mutating func block(slot: String, because why: String) {
        blocked[slot] = why
    }

    /// The request-search kinds a search of the app asks: movies and series (`video`), and the
    /// albums of the music the app plays. The app has no books.
    public static let searchKinds: [RequestSearchKind] = [.video, .music]

    /// What a kid's search finds to ask for: every kind in `kinds` asked at once, the answers in
    /// the kinds' order. A kind that fails (the search is closed, an addon does not answer) or
    /// finds nothing leaves nothing, and no word is said.
    public static func candidates(
        kinds: [RequestSearchKind] = KidRequestBook.searchKinds,
        ask: @escaping @Sendable (RequestSearchKind) async throws -> [KidCandidate]
    ) async -> [KidCandidate] {
        await withTaskGroup(of: (Int, [KidCandidate]).self) { group in
            for (index, kind) in kinds.enumerated() {
                group.addTask { (index, (try? await ask(kind)) ?? []) }
            }
            var answers: [(Int, [KidCandidate])] = []
            for await answer in group { answers.append(answer) }
            var seen = Set<String>()
            return answers.sorted { $0.0 < $1.0 }.flatMap(\.1).filter { seen.insert($0.id).inserted }
        }
    }
}
