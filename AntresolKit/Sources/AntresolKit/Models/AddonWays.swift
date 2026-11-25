import Foundation

// The apps' side of the `x/app` protocol of the server's addons: what an addon offers a title
// (its ways), where a way is offered, and what an addon's search finds. The apps never know an
// addon's id or wording: every label comes from the server in the profile's language.

/// The glyph a way asks for. The app draws its own symbol for it; anything else is `play`.
public enum WayIcon: String, Hashable, Sendable {
    case play, download, globe, list

    public init(serverValue: String?) {
        self = serverValue.flatMap(WayIcon.init(rawValue:)) ?? .play
    }
}

/// What a way is for: `watch` plays (the «Watch» choice, or the first button when there is no
/// Play), `keep` puts a copy on the server (a round button with a state ring).
public enum WayRole: String, Hashable, Sendable {
    case watch, keep
}

/// Where a way is offered: for anything, only for what the library does not have, or only for
/// what it has.
public enum WayScope: String, Hashable, Sendable {
    case any, outside, inside
}

/// One way of `GET x/app` (`ways`). The id is opaque: the app only passes it back.
public struct AppWay: Decodable, Hashable, Sendable {
    public var id: String
    /// The button's label, already translated.
    public var label: String
    public var icon: WayIcon
    public var role: WayRole
    /// `movie` and/or `series`.
    public var kinds: [String]
    public var scope: WayScope
    /// Can be called for one episode (season and episode given).
    public var episodes: Bool

    public init(
        id: String, label: String, icon: WayIcon = .play, role: WayRole = .watch,
        kinds: [String] = ["movie", "series"], scope: WayScope = .any, episodes: Bool = false
    ) {
        self.id = id
        self.label = label
        self.icon = icon
        self.role = role
        self.kinds = kinds
        self.scope = scope
        self.episodes = episodes
    }

    enum CodingKeys: String, CodingKey { case id, label, icon, role, kinds, scope, episodes }

    /// A way without an id or a label, or of a role or scope this app does not know, does not
    /// decode: it is left out rather than shown wrong.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        label = try c.decode(String.self, forKey: .label).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, !label.isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: .id, in: c, debugDescription: "empty way")
        }
        icon = WayIcon(serverValue: c.optional(.icon))
        guard let role = WayRole(rawValue: try c.decode(String.self, forKey: .role)) else {
            throw DecodingError.dataCorruptedError(forKey: .role, in: c, debugDescription: "unknown role")
        }
        self.role = role
        kinds = c.value(.kinds, default: [])
        let scopeName: String = c.value(.scope, default: WayScope.any.rawValue)
        guard let scope = WayScope(rawValue: scopeName) else {
            throw DecodingError.dataCorruptedError(forKey: .scope, in: c, debugDescription: "unknown scope")
        }
        self.scope = scope
        episodes = c.value(.episodes, default: false)
    }
}

/// `search` of `GET x/app`: the addon searches titles, under this heading.
public struct AppSearch: Decodable, Hashable, Sendable {
    public var label: String

    public init(label: String) {
        self.label = label
    }

    enum CodingKeys: String, CodingKey { case label }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        label = try c.decode(String.self, forKey: .label).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// `GET /api/addons/{id}/x/app`: what an addon offers the apps.
public struct AppInfo: Decodable, Hashable, Sendable {
    /// The protocol version this app speaks. An addon that answers another one is left out.
    public static let supportedVersion = 1

    public var v: Int
    /// In the order they are shown.
    public var ways: [AppWay]
    public var search: AppSearch?

    public init(v: Int = AppInfo.supportedVersion, ways: [AppWay] = [], search: AppSearch? = nil) {
        self.v = v
        self.ways = ways
        self.search = search
    }

    enum CodingKeys: String, CodingKey { case v, ways, search }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        v = try c.decode(Int.self, forKey: .v)
        guard v == Self.supportedVersion else {
            throw DecodingError.dataCorruptedError(forKey: .v, in: c, debugDescription: "unsupported version \(v)")
        }
        // A malformed way drops that way only.
        let entries: [Lenient<AppWay>] = c.value(.ways, default: [])
        var seen = Set<String>()
        ways = entries.compactMap(\.value).filter { seen.insert($0.id).inserted }
        let found: AppSearch? = c.optional(.search)
        search = found.flatMap { $0.label.isEmpty ? nil : $0 }
    }
}

/// What a way is called for: a title, and one of its episodes when `season` and `episode` are set.
public struct WayTarget: Hashable, Sendable {
    /// `movie` or `series`.
    public var kind: String
    public var tmdbId: Int
    public var season: Int?
    public var episode: Int?
    /// The library has it (for an episode: has that episode).
    public var inLibrary: Bool

    public init(kind: String, tmdbId: Int, season: Int? = nil, episode: Int? = nil, inLibrary: Bool) {
        self.kind = kind
        self.tmdbId = tmdbId
        self.season = season
        self.episode = episode
        self.inLibrary = inLibrary
    }

    public var isEpisode: Bool { season != nil && episode != nil }

    /// The same title's episode.
    public func episode(season: Int, episode: Int, inLibrary: Bool) -> WayTarget {
        WayTarget(kind: kind, tmdbId: tmdbId, season: season, episode: episode, inLibrary: inLibrary)
    }
}

/// A way of one addon: the addon's id (only ever used to build its paths) and the way itself.
public struct AddonWay: Hashable, Identifiable, Sendable {
    public let addonId: String
    public let way: AppWay

    public init(addonId: String, way: AppWay) {
        self.addonId = addonId
        self.way = way
    }

    /// Unique across addons: two addons may use the same way id.
    public var id: String { "\(addonId)/\(way.id)" }
    public var label: String { way.label }
    public var icon: WayIcon { way.icon }
    public var role: WayRole { way.role }

    /// Whether the way is offered for `target`: its kind, its scope against what the library
    /// has, and for an episode only a way that can be called for one.
    public func isOffered(for target: WayTarget) -> Bool {
        guard way.kinds.contains(target.kind) else { return false }
        switch way.scope {
        case .any: break
        case .outside: if target.inLibrary { return false }
        case .inside: if !target.inLibrary { return false }
        }
        return !target.isEpisode || way.episodes
    }
}

/// An addon's search, with the heading its results show under.
public struct AddonSearch: Hashable, Identifiable, Sendable {
    public let addonId: String
    public let label: String

    public init(addonId: String, label: String) {
        self.addonId = addonId
        self.label = label
    }

    public var id: String { addonId }
}

/// The ways and searches of every addon open to the profile, merged in the order of the addons'
/// ids (as the web does).
public struct AddonCatalogSnapshot: Hashable, Sendable {
    public var ways: [AddonWay]
    public var searches: [AddonSearch]

    public init(ways: [AddonWay] = [], searches: [AddonSearch] = []) {
        self.ways = ways
        self.searches = searches
    }

    public static let empty = AddonCatalogSnapshot()

    public var isEmpty: Bool { ways.isEmpty && searches.isEmpty }

    /// The ways offered for `target`, in order; only those of `role` when it is given.
    public func ways(for target: WayTarget, role: WayRole? = nil) -> [AddonWay] {
        ways.filter { (role == nil || $0.role == role) && $0.isOffered(for: target) }
    }

    public func way(id: String) -> AddonWay? {
        ways.first { $0.id == id }
    }

    /// Builds the snapshot from the addons' answers: ordered by addon id, an addon appearing
    /// once.
    static func merging(_ infos: [(addonId: String, info: AppInfo)]) -> AddonCatalogSnapshot {
        var seen = Set<String>()
        let ordered = infos.filter { seen.insert($0.addonId).inserted }.sorted { $0.addonId < $1.addonId }
        return AddonCatalogSnapshot(
            ways: ordered.flatMap { entry in entry.info.ways.map { AddonWay(addonId: entry.addonId, way: $0) } },
            searches: ordered.compactMap { entry in entry.info.search.map { AddonSearch(addonId: entry.addonId, label: $0.label) } }
        )
    }
}

/// An addon id is a short word; one with any other character is never put in a path.
public enum AddonID {
    public static func isValid(_ id: String) -> Bool {
        !id.isEmpty && id.utf8.count <= 64 && id.unicodeScalars.allSatisfy {
            ($0.value >= 0x30 && $0.value <= 0x39) || ($0.value >= 0x41 && $0.value <= 0x5A)
                || ($0.value >= 0x61 && $0.value <= 0x7A) || $0 == "-" || $0 == "_"
        }
    }
}

// MARK: - Search

/// A title an addon's search found (`GET x/app/search`).
public struct AddonTitle: Decodable, Hashable, Identifiable, Sendable {
    /// `movie` or `series`.
    public var kind: String
    public var tmdbId: Int
    public var title: String
    public var year: Int?
    /// An absolute URL or a server path.
    public var poster: String
    public var overview: String
    public var inLibrary: Bool
    public var libraryItemId: Int?

    public init(
        kind: String, tmdbId: Int, title: String, year: Int? = nil, poster: String = "",
        overview: String = "", inLibrary: Bool = false, libraryItemId: Int? = nil
    ) {
        self.kind = kind
        self.tmdbId = tmdbId
        self.title = title
        self.year = year
        self.poster = poster
        self.overview = overview
        self.inLibrary = inLibrary
        self.libraryItemId = libraryItemId
    }

    public var id: String { "\(kind)-\(tmdbId)" }

    enum CodingKeys: String, CodingKey { case kind, tmdbId, title, year, poster, overview, inLibrary, libraryItemId }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(String.self, forKey: .kind)
        tmdbId = try c.decode(Int.self, forKey: .tmdbId)
        title = try c.decode(String.self, forKey: .title)
        guard Self.kinds.contains(kind), tmdbId > 0, !title.isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: .tmdbId, in: c, debugDescription: "not a title")
        }
        year = c.optional(.year)
        poster = c.value(.poster, default: "")
        overview = c.value(.overview, default: "")
        inLibrary = c.value(.inLibrary, default: false)
        libraryItemId = c.optional(.libraryItemId)
    }

    static let kinds: Set<String> = ["movie", "series"]

    /// The library's page of it, when the library has it.
    public var libraryId: Int? {
        inLibrary ? libraryItemId.flatMap { $0 > 0 ? $0 : nil } : nil
    }
}

/// `{"titles": [Title]}`.
public struct AddonTitleList: Decodable, Sendable {
    public var titles: [AddonTitle]

    enum CodingKeys: String, CodingKey { case titles }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // A malformed entry drops that entry only; a title listed twice shows once.
        let entries: [Lenient<AddonTitle>] = c.value(.titles, default: [])
        var seen = Set<String>()
        titles = entries.compactMap(\.value).filter { seen.insert($0.id).inserted }
    }
}

/// One addon's results in the Search tab, after the library's: under the addon's own heading.
public struct AddonSearchSection: Hashable, Identifiable, Sendable {
    public let addonId: String
    public let label: String
    public let titles: [AddonTitle]

    public init(addonId: String, label: String, titles: [AddonTitle]) {
        self.addonId = addonId
        self.label = label
        self.titles = titles
    }

    public var id: String { addonId }
}

/// A title off the library (`GET /api/title/{kind}/{tmdbId}`): what the page of a TMDB title shows.
public struct TitleInfo: Decodable, Hashable, Sendable {
    public var tmdbId: Int
    public var kind: String
    public var title: String
    public var year: Int?
    public var poster: String
    public var backdrop: String
    public var overview: String
    public var inLibrary: Bool
    public var libraryItemId: Int?
    public var originalTitle: String?
    public var genres: [String]
    /// Minutes.
    public var runtime: Int?
    public var rating: String?
    public var cast: [CastMember]
    public var seasons: [TitleSeason]
    /// A kid's page: whether the title may be asked for and the profile's request of it (nil: not a kid).
    public var kidRequest: RequestState?

    public struct TitleSeason: Decodable, Hashable, Sendable {
        public var number: Int
        public var episodes: Int

        enum CodingKeys: String, CodingKey { case number, episodes }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            number = try c.decode(Int.self, forKey: .number)
            episodes = c.value(.episodes, default: 0)
        }
    }

    enum CodingKeys: String, CodingKey {
        case tmdbId, kind, title, year, poster, backdrop, overview, inLibrary, libraryItemId
        case originalTitle, genres, runtime, rating, cast, seasons, kidRequest
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tmdbId = try c.decode(Int.self, forKey: .tmdbId)
        kind = try c.decode(String.self, forKey: .kind)
        title = c.value(.title, default: "")
        let listedYear: Int? = c.optional(.year)
        year = listedYear.flatMap { $0 > 0 ? $0 : nil }
        poster = c.value(.poster, default: "")
        backdrop = c.value(.backdrop, default: "")
        overview = c.value(.overview, default: "")
        inLibrary = c.value(.inLibrary, default: false)
        libraryItemId = c.optional(.libraryItemId)
        originalTitle = c.optional(.originalTitle)
        genres = c.value(.genres, default: [])
        runtime = c.optional(.runtime)
        rating = c.optional(.rating)
        cast = c.value(.cast, default: [])
        seasons = c.value(.seasons, default: [])
        kidRequest = c.optional(.kidRequest)
    }

    /// The target of its ways: it is off the library unless the server says otherwise.
    public var target: WayTarget {
        WayTarget(kind: kind, tmdbId: tmdbId, inLibrary: inLibrary)
    }
}
