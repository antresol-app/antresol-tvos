import Foundation

/// `GET /api/channels/epg?from=&hours=`: every channel the profile sees (the list order)
/// with the programmes that overlap `[from, to)`.
public struct ChannelEPGWindow: Decodable, Hashable, Sendable {
    public var from: Date
    public var to: Date
    public var channels: [ChannelEPG]

    public init(from: Date, to: Date, channels: [ChannelEPG]) {
        self.from = from
        self.to = to
        self.channels = channels
    }

    enum CodingKeys: String, CodingKey { case from, to, channels }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        from = Timestamp.parse(c.optional(.from)) ?? Date(timeIntervalSince1970: 0)
        to = Timestamp.parse(c.optional(.to)) ?? Date(timeIntervalSince1970: 0)
        channels = c.value(.channels, default: [])
    }
}

/// A channel's row of the guide.
public struct ChannelEPG: Decodable, Hashable, Identifiable, Sendable {
    public var id: Int
    public var number: Int
    public var name: String
    public var category: String
    public var favorite: Bool
    /// By start.
    public var programs: [ChannelProgram]
    /// The uploaded logo, when the server sends it with the row ("" otherwise; the guide
    /// also takes it from the channel list).
    public var logoUrl: String
    /// An external channel's row (its stream comes with the channel list).
    public var external: Bool
    /// As `Channel.categories`.
    public var categories: [String]?

    public init(
        id: Int, number: Int, name: String, category: String = "", favorite: Bool = false, programs: [ChannelProgram] = [],
        logoUrl: String = "", external: Bool = false, categories: [String]? = nil
    ) {
        self.categories = categories
        self.logoUrl = logoUrl
        self.external = external
        self.id = id
        self.number = number
        self.name = name
        self.category = category
        self.favorite = favorite
        self.programs = programs.sorted { $0.start < $1.start }
    }

    enum CodingKeys: String, CodingKey { case id, number, name, category, favorite, programs, logoUrl, external, categories }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        number = c.value(.number, default: 0)
        name = c.value(.name, default: "")
        category = c.value(.category, default: "")
        favorite = c.value(.favorite, default: false)
        programs = (c.value(.programs, default: [ChannelProgram]())).sorted { $0.start < $1.start }
        logoUrl = c.value(.logoUrl, default: "")
        external = c.value(.external, default: false)
        categories = c.optional(.categories)
    }

    /// The row as a channel (no now / next), for filters and the player.
    public var channel: Channel {
        Channel(
            id: id, number: number, name: name, category: category, favorite: favorite, logoUrl: logoUrl, external: external,
            categories: categories
        )
    }

    /// The row as the list's channel (an external one with its stream, which the row lacks).
    public func channel(in list: [Channel]) -> Channel {
        guard var full = list.first(where: { $0.id == id }) else { return channel }
        full.favorite = favorite
        return full
    }

    /// The programme on air at `date`, else the nearest one: the first to start after it,
    /// else the last before it. nil for a row without programmes.
    public func program(near date: Date) -> ChannelProgram? {
        if let onAir = programs.first(where: { $0.isOnAir(at: date) }) { return onAir }
        return programs.first { $0.start > date } ?? programs.last
    }
}

/// The guide's programmes as loaded so far: windows of `GET /api/channels/epg` merged into
/// one row per channel. Rows follow the latest window's order (the list order).
public struct ChannelGuideGrid: Hashable, Sendable {
    public private(set) var rows: [ChannelEPG] = []
    /// What is loaded: `[loadedFrom, loadedTo)`; nil before the first window.
    public private(set) var loadedFrom: Date?
    public private(set) var loadedTo: Date?

    public init() {}

    public init(_ window: ChannelEPGWindow) {
        merge(window)
    }

    /// Adds a window (a page of the guide). The page is the newer word on its span, and
    /// the server gives a programme's id (`<channel>-<seq>`) to another programme when a
    /// schedule is rebuilt, so nothing known is trusted over it:
    /// - the page's programmes all come in; under the same key, or from the same start,
    ///   the page's copy replaces the known one;
    /// - a known programme that starts inside the page's span is dropped (the page would
    ///   have listed it);
    /// - a known programme that starts outside the span and lies over one of the page's
    ///   is dropped when it is a library programme (a channel's own schedule has no two
    ///   programmes at once: it is stale) or reaches into the span (the page lists all
    ///   that do). An external guide's entry wholly outside the span stays: such guides
    ///   do overlap, and the page says nothing about it;
    /// - the two halves of a programme cut by the pages' common edge become one
    ///   (`joined`), unless that would give two of the page's programmes one key or lay
    ///   the joined span over another of them (the known half is stale then);
    /// - an external row that comes empty in a page whose external rows are all empty is
    ///   no word about that channel, and what is known stays: the server asks its guide
    ///   store once for all external channels and, when that fails, still answers with
    ///   every one of them empty. (A library row's emptiness is the truth: an error
    ///   there fails the whole request.)
    /// - keys are unique within a row, and channels the window no longer has are dropped
    ///   (the profile does not see them any more).
    public mutating func merge(_ window: ChannelEPGWindow) {
        var known: [Int: ChannelEPG] = [:]
        for row in rows { known[row.id] = row }
        let externalGuideAnswered = window.channels.contains { $0.external && !$0.programs.isEmpty }
        rows = window.channels.map { fresh in
            guard let old = known[fresh.id] else { return Self.uniqueKeys(fresh) }
            if fresh.external, fresh.programs.isEmpty, !externalGuideAnswered {
                var row = fresh
                row.programs = old.programs
                return row
            }
            var page = fresh.programs
            for index in page.indices {
                let whole = Self.joined(page[index], with: old.programs, in: window)
                guard whole != page[index] else { continue }
                let clashes = fresh.programs.indices.contains { other in
                    other != index && (fresh.programs[other].key == whole.key
                        || (fresh.programs[other].start < whole.end && whole.start < fresh.programs[other].end))
                }
                if !clashes { page[index] = whole }
            }
            var byKey: [String: ChannelProgram] = [:]
            for program in page { byKey[program.key] = program }
            let listed = Array(byKey.values)
            for program in old.programs where byKey[program.key] == nil {
                if program.start >= window.from && program.start < window.to { continue }
                let isExternal = fresh.external || program.kind == "external"
                let superseded = !isExternal || (program.end > window.from && program.start < window.to)
                let replaced = listed.contains {
                    $0.start == program.start || (superseded && $0.start < program.end && program.start < $0.end)
                }
                if !replaced { byKey[program.key] = program }
            }
            var row = fresh
            row.programs = byKey.values.sorted { ($0.start, $0.key) < ($1.start, $1.key) }
            return row
        }
        loadedFrom = min(loadedFrom ?? window.from, window.from)
        loadedTo = max(loadedTo ?? window.to, window.to)
    }

    /// A row as it came, with one programme per key (the later one in the page).
    private static func uniqueKeys(_ row: ChannelEPG) -> ChannelEPG {
        var byKey: [String: ChannelProgram] = [:]
        for program in row.programs { byKey[program.key] = program }
        guard byKey.count != row.programs.count else { return row }
        var row = row
        row.programs = byKey.values.sorted { ($0.start, $0.key) < ($1.start, $1.key) }
        return row
    }

    /// A programme of several files that a window's edge cuts comes under the id of its
    /// first file inside that window and without the files outside it: the next window has
    /// the same programme under another id, from another start. With the part already
    /// known (the same item, overlapping, reaching past the edge that cut `fresh`) it is
    /// one programme: the whole span, under the key it already had (the guide's identity
    /// and focus).
    ///
    /// Only a library programme can be recognised so: an external guide's entries carry no
    /// item (`itemId` 0 for all of them), and two of those that overlap are two programmes.
    /// Under the same id the known copy is this programme joined before only when the two
    /// agree on the edge that is not cut; otherwise a rebuilt schedule moved it, and the
    /// fresh copy stands. (A moved programme that also changed its id cannot be told from
    /// a cut one by its times.)
    static func joined(_ fresh: ChannelProgram, with known: [ChannelProgram], in window: ChannelEPGWindow) -> ChannelProgram {
        guard !fresh.id.isEmpty, fresh.itemId != 0, !fresh.external, fresh.kind != "external" else { return fresh }
        let part = known.first { old in
            guard !old.id.isEmpty, old.itemId == fresh.itemId, !old.external, old.start < fresh.end, fresh.start < old.end else {
                return false
            }
            let sameId = old.id == fresh.id
            // Cut at the window's start: the known part has the head.
            let head = fresh.start <= window.from && old.start < fresh.start && (!sameId || old.end == fresh.end)
            // Cut at the window's end: the known part has the tail. Under another id it
            // may also end where the fresh one does: the programme's last files, seen
            // first from the later window under their own id, and now listed whole.
            let tail = fresh.end >= window.to && (sameId ? old.end > fresh.end && old.start == fresh.start : old.end >= fresh.end)
            return head || tail
        }
        guard let part else { return fresh }
        var whole = fresh
        whole.id = part.id
        whole.start = min(part.start, fresh.start)
        whole.end = max(part.end, fresh.end)
        return whole
    }

    /// Gives rows that came without a logo the channel list's one.
    public mutating func applyLogos(from channels: [Channel]) {
        var logos: [Int: String] = [:]
        for channel in channels where !channel.logoUrl.isEmpty { logos[channel.id] = channel.logoUrl }
        for index in rows.indices where rows[index].logoUrl.isEmpty {
            rows[index].logoUrl = logos[rows[index].id] ?? ""
        }
    }

    /// Marks a channel as a favourite or not (after the API call succeeded).
    public mutating func setFavorite(_ favorite: Bool, channelId: Int) {
        guard let index = rows.firstIndex(where: { $0.id == channelId }) else { return }
        rows[index].favorite = favorite
    }

    /// The rows a filter shows, by number.
    public func rows(_ filter: ChannelFilter) -> [ChannelEPG] {
        rows.filter { filter.matches($0.channel) }.sorted { ($0.number, $0.id) < ($1.number, $1.id) }
    }

    /// The median length of the programmes in `rows`, in seconds (nil when there are none).
    public static func typicalLength(of rows: [ChannelEPG]) -> TimeInterval? {
        let lengths = rows.flatMap(\.programs).map { $0.end.timeIntervalSince($0.start) }.filter { $0 > 0 }.sorted()
        guard !lengths.isEmpty else { return nil }
        return lengths[lengths.count / 2]
    }
}

/// How the guide lays time out: points per minute and the ruler's tick. A real schedule
/// (films, hour-long episodes) gets the TV guide's half-hour ≈ 320 pt; a schedule of
/// short programmes is zoomed in until a typical programme is wide enough to read.
public struct GuideScale: Hashable, Sendable {
    public var pointsPerMinute: Double
    /// Minutes between the ruler's ticks.
    public var tickMinutes: Int

    public init(pointsPerMinute: Double, tickMinutes: Int) {
        self.pointsPerMinute = pointsPerMinute
        self.tickMinutes = tickMinutes
    }

    /// The width a typical programme should get.
    public static let typicalWidth: Double = 360
    /// Half an hour is at least this wide (a TV guide's usual scale).
    public static let halfHourWidth: Double = 320
    /// Never closer than this (a 3-minute clip is still a small block).
    public static let maxPointsPerMinute: Double = 60
    /// The ruler's ticks are at least this far apart.
    public static let minTickWidth: Double = 220

    /// The scale for programmes of `typicalLength` seconds (nil: the usual scale).
    public static func fitting(typicalLength: TimeInterval?) -> GuideScale {
        let minPPM = halfHourWidth / 30
        var ppm = minPPM
        if let typicalLength, typicalLength > 0 {
            ppm = min(max(typicalWidth / (typicalLength / 60), minPPM), maxPointsPerMinute)
        }
        let tick = [5, 10, 15, 30, 60].first { Double($0) * ppm >= minTickWidth } ?? 60
        return GuideScale(pointsPerMinute: ppm, tickMinutes: tick)
    }

    /// Where `date` is on the time axis that starts at `origin`, in points. The ruler's
    /// ticks, the programme blocks and the now line all use this, so they cannot drift
    /// apart.
    public func x(_ date: Date, from origin: Date) -> Double {
        width(date.timeIntervalSince(origin))
    }

    /// The time at `x` points on the axis that starts at `origin`.
    public func date(atX x: Double, from origin: Date) -> Date {
        origin.addingTimeInterval(interval(x))
    }

    public func width(_ interval: TimeInterval) -> Double {
        interval / 60 * pointsPerMinute
    }

    public func interval(_ width: Double) -> TimeInterval {
        width / pointsPerMinute * 60
    }

    /// `date` rounded down to a tick (ticks fall on whole minutes of the hour).
    public func tick(atOrBefore date: Date) -> Date {
        let step = TimeInterval(tickMinutes * 60)
        return Date(timeIntervalSince1970: (date.timeIntervalSince1970 / step).rounded(.down) * step)
    }
}
