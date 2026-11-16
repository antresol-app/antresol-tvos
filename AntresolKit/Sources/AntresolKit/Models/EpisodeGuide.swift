import Foundation

/// `GET /api/tracking/{series|movie}/{tmdbId}/episodes` (server 0.5.0+): every episode the
/// title has on TMDB, with the sources the profile may use. A library file is a source of
/// kind `library` whose `meta.itemId` is the episode item to play.
public struct TrackingEpisodes: Decodable, Hashable, Sendable {
    public var title: TrackingTitle
    public var episodes: [TrackingEpisode]

    public init(title: TrackingTitle, episodes: [TrackingEpisode]) {
        self.title = title
        self.episodes = episodes
    }

    enum CodingKeys: String, CodingKey { case title, episodes }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = c.value(.title, default: TrackingTitle())
        episodes = c.value(.episodes, default: [])
    }
}

public struct TrackingTitle: Decodable, Hashable, Sendable {
    /// "series" or "movie".
    public var kind: String
    public var tmdbId: Int
    public var name: String
    public var poster: String
    /// TMDB status, e.g. "Returning Series", "Ended".
    public var status: String
    /// The library item, when the title is in the library.
    public var itemId: Int?

    public init(kind: String = "", tmdbId: Int = 0, name: String = "", poster: String = "", status: String = "", itemId: Int? = nil) {
        self.kind = kind
        self.tmdbId = tmdbId
        self.name = name
        self.poster = poster
        self.status = status
        self.itemId = itemId
    }

    enum CodingKeys: String, CodingKey { case kind, tmdbId, name, poster, status, itemId }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = c.value(.kind, default: "")
        tmdbId = c.value(.tmdbId, default: 0)
        name = c.value(.name, default: "")
        poster = c.value(.poster, default: "")
        status = c.value(.status, default: "")
        itemId = c.optional(.itemId)
    }
}

public struct TrackingEpisode: Decodable, Hashable, Sendable {
    public var season: Int
    public var number: Int
    public var name: String
    /// `YYYY-MM-DD`, or `""` when unknown (also for library files TMDB lacks).
    public var airDate: String
    public var watched: Bool
    public var positionSec: Int?
    /// Unwatched and news by the feed's rule.
    public var new: Bool
    public var sources: [TrackingSource]

    public init(
        season: Int, number: Int, name: String = "", airDate: String = "", watched: Bool = false,
        positionSec: Int? = nil, new: Bool = false, sources: [TrackingSource] = []
    ) {
        self.season = season
        self.number = number
        self.name = name
        self.airDate = airDate
        self.watched = watched
        self.positionSec = positionSec
        self.new = new
        self.sources = sources
    }

    enum CodingKeys: String, CodingKey { case season, number, name, airDate, watched, positionSec, new, sources }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        season = c.value(.season, default: 0)
        number = c.value(.number, default: 0)
        name = c.value(.name, default: "")
        airDate = c.value(.airDate, default: "")
        watched = c.value(.watched, default: false)
        positionSec = c.optional(.positionSec)
        new = c.value(.new, default: false)
        sources = c.value(.sources, default: [])
    }

    /// The library episode item to play, if the episode is downloaded.
    public var libraryItemId: Int? {
        sources.first { $0.kind == TrackingSource.library && ($0.meta.itemId ?? 0) > 0 }?.meta.itemId
    }
}

public struct TrackingSource: Decodable, Hashable, Sendable {
    public static let library = "library"

    /// An opaque source kind; "library" is the core's.
    public var kind: String
    public var ref: String
    public var provider: String?
    public var quality: String?
    public var labels: [String]
    public var firstSeen: String
    public var meta: TrackingSourceMeta

    public init(kind: String, ref: String = "", labels: [String] = [], firstSeen: String = "", meta: TrackingSourceMeta = TrackingSourceMeta()) {
        self.kind = kind
        self.ref = ref
        self.labels = labels
        self.firstSeen = firstSeen
        self.meta = meta
    }

    enum CodingKeys: String, CodingKey { case kind, ref, provider, quality, labels, firstSeen, meta }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = c.value(.kind, default: "")
        ref = c.value(.ref, default: "")
        provider = c.optional(.provider)
        quality = c.optional(.quality)
        labels = c.value(.labels, default: [])
        firstSeen = c.value(.firstSeen, default: "")
        meta = c.value(.meta, default: TrackingSourceMeta())
    }
}

/// The fields of a source's `meta` the TV app reads (the server sends more).
public struct TrackingSourceMeta: Decodable, Hashable, Sendable {
    /// Library: the episode (or movie) item to play.
    public var itemId: Int?
    /// Library: the file.
    public var fileId: Int?

    public init(itemId: Int? = nil, fileId: Int? = nil) {
        self.itemId = itemId
        self.fileId = fileId
    }

    enum CodingKeys: String, CodingKey { case itemId, fileId }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        itemId = c.optional(.itemId)
        fileId = c.optional(.fileId)
    }
}

// MARK: - The guide a series page shows

/// The seasons and episodes of a series page: the library's episodes merged into the
/// tracking answer's full list, or the library's alone when there is no answer.
public struct EpisodeGuide: Hashable, Sendable {
    public var seasons: [GuideSeason]
    /// Built from the tracking answer: episodes are marked downloaded or not.
    public var isFull: Bool

    /// - Parameters:
    ///   - library: the series' seasons from `GET /api/items/{id}`.
    ///   - tracking: the tracking answer, or nil (old server, hidden title, error).
    ///   - today: `YYYY-MM-DD` of the local day; episodes airing later are upcoming.
    public init(library: [SeasonInfo], tracking: TrackingEpisodes?, today: String) {
        guard let tracking, !tracking.episodes.isEmpty else {
            seasons = library.map { season in
                GuideSeason(
                    number: season.number, title: season.title, libraryId: season.id,
                    episodes: season.episodes.map { GuideEpisode(card: $0) }
                )
            }
            isFull = false
            return
        }
        isFull = true

        let cards = library.flatMap(\.episodes)
        let cardById = Dictionary(cards.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var used = Set<Int>()
        var entries: [GuideEpisode] = tracking.episodes.map { episode in
            var card: EpisodeCard?
            if let itemId = episode.libraryItemId {
                card = cardById[itemId] ?? EpisodeCard(
                    card: Card(id: itemId, kind: .episode, title: episode.name, season: episode.season, episode: episode.number),
                    seasonNo: episode.season, episodeNo: episode.number, watched: episode.watched
                )
                used.insert(itemId)
            }
            return GuideEpisode(tracking: episode, card: card, today: today)
        }
        // Library episodes the answer does not name (an index not refreshed yet) take
        // their (season, number) slot, or are added.
        for card in cards where !used.contains(card.id) {
            if let i = entries.firstIndex(where: { $0.season == card.seasonNo && $0.number == card.episodeNo && $0.card == nil }) {
                entries[i] = GuideEpisode(card: card, airDate: entries[i].airDate)
            } else {
                entries.append(GuideEpisode(card: card))
            }
        }
        entries.sort { ($0.season, $0.number) < ($1.season, $1.number) }

        var order: [Int] = []
        var bySeason: [Int: [GuideEpisode]] = [:]
        for entry in entries {
            if bySeason[entry.season] == nil { order.append(entry.season) }
            bySeason[entry.season, default: []].append(entry)
        }
        seasons = order.map { number in
            let info = library.first { $0.number == number }
            return GuideSeason(number: number, title: info?.title ?? "", libraryId: info?.id, episodes: bySeason[number] ?? [])
        }
    }

    /// The season to open: the one holding `preferredItemId` (a season or episode item),
    /// else the first with a downloaded episode, else the first.
    public func initialSeason(preferredItemId: Int?) -> Int? {
        if let preferredItemId,
           let season = seasons.first(where: { $0.libraryId == preferredItemId || $0.episodes.contains { $0.card?.id == preferredItemId } }) {
            return season.number
        }
        return (seasons.first { $0.episodes.contains { $0.isDownloaded } } ?? seasons.first)?.number
    }

    /// The local day as `YYYY-MM-DD`, to compare with `airDate`.
    public static func day(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}

public struct GuideSeason: Hashable, Identifiable, Sendable {
    public var number: Int
    /// The library's title, `""` when the season is not in the library.
    public var title: String
    /// The library season item, if any.
    public var libraryId: Int?
    public var episodes: [GuideEpisode]

    public var id: Int { number }
}

public struct GuideEpisode: Hashable, Identifiable, Sendable {
    public enum State: Hashable, Sendable {
        /// In the library: plays as before.
        case downloaded
        /// Aired but not in the library.
        case missing
        /// Airs after today (`airDate` may be `""` when TMDB has no date yet).
        case upcoming
    }

    public var season: Int
    public var number: Int
    public var name: String
    public var airDate: String
    public var state: State
    /// The library episode, when downloaded.
    public var card: EpisodeCard?
    /// The profile's watched mark (the library card's when downloaded).
    public var watched: Bool

    public var id: String { card.map { "item-\($0.id)" } ?? "ep-\(season)-\(number)" }

    public var isDownloaded: Bool { state == .downloaded }

    /// A library episode.
    public init(card: EpisodeCard, airDate: String = "") {
        season = card.seasonNo
        number = card.episodeNo
        name = card.title
        self.airDate = airDate
        state = .downloaded
        self.card = card
        watched = card.watched
    }

    /// An episode of the tracking answer; `card` is its library episode, if any.
    public init(tracking episode: TrackingEpisode, card: EpisodeCard?, today: String) {
        season = episode.season
        number = episode.number
        if let title = card?.title, !title.isEmpty {
            name = title
        } else {
            name = episode.name
        }
        airDate = episode.airDate
        self.card = card
        if card != nil {
            state = .downloaded
        } else if episode.airDate.isEmpty || episode.airDate > today {
            state = .upcoming
        } else {
            state = .missing
        }
        watched = card?.watched ?? episode.watched
    }

    /// The air date as a local-midnight date, for display.
    public func airDay(calendar: Calendar = .current) -> Date? {
        let parts = airDate.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }
}
