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

    public init(
        id: Int, number: Int, name: String, category: String = "", favorite: Bool = false, programs: [ChannelProgram] = [],
        logoUrl: String = "", external: Bool = false
    ) {
        self.logoUrl = logoUrl
        self.external = external
        self.id = id
        self.number = number
        self.name = name
        self.category = category
        self.favorite = favorite
        self.programs = programs.sorted { $0.start < $1.start }
    }

    enum CodingKeys: String, CodingKey { case id, number, name, category, favorite, programs, logoUrl, external }

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
    }

    /// The row as a channel (no now / next), for filters and the player.
    public var channel: Channel {
        Channel(id: id, number: number, name: name, category: category, favorite: favorite, logoUrl: logoUrl, external: external)
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

    /// Adds a window: new channels and programmes come in, a programme already known is
    /// replaced by the fresh copy (same `key`), the two halves of one cut by the windows'
    /// common edge become one (`joined`), channels the window no longer has are dropped
    /// (the profile does not see them any more).
    public mutating func merge(_ window: ChannelEPGWindow) {
        var known: [Int: ChannelEPG] = [:]
        for row in rows { known[row.id] = row }
        rows = window.channels.map { fresh in
            guard let old = known[fresh.id] else { return fresh }
            let freshPrograms = fresh.programs.map { Self.joined($0, with: old.programs, in: window) }
            var byKey: [String: ChannelProgram] = [:]
            for program in old.programs { byKey[program.key] = program }
            for program in freshPrograms { byKey[program.key] = program }
            var row = fresh
            // Programmes of a rebuilt schedule may overlap old copies: the fresh ones win.
            row.programs = byKey.values
                .filter { candidate in
                    freshPrograms.contains { $0.key == candidate.key }
                        || !freshPrograms.contains { $0.start < candidate.end && candidate.start < $0.end }
                }
                .sorted { $0.start < $1.start }
            return row
        }
        loadedFrom = min(loadedFrom ?? window.from, window.from)
        loadedTo = max(loadedTo ?? window.to, window.to)
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
            // Cut at the window's end: the known part has the tail.
            let tail = fresh.end >= window.to && old.end > fresh.end && (!sameId || old.start == fresh.start)
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
