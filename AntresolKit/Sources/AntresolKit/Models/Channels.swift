import Foundation

/// A live channel made of the library (`GET /api/channels`, «ТВ»). The server plays its
/// programmes back to back; apps only list channels, show what is on and play the live
/// stream. Editing (`rules`) is web only and not decoded.
public struct Channel: Decodable, Hashable, Identifiable, Sendable {
    public var id: Int
    /// The channel number: the order of the list and of channel up / down.
    public var number: Int
    public var name: String
    /// The section the channel is in on the TV tab.
    public var category: String
    public var personal: Bool
    public var auto: Bool
    public var enabled: Bool
    /// The logo's gradient, 0…6: the avatar gradients `grad-1` … `grad-7`.
    public var logo: Int
    /// What is on air, when the server knows.
    public var now: ChannelProgram?
    public var next: ChannelProgram?

    public init(
        id: Int, number: Int, name: String, category: String = "", personal: Bool = false, auto: Bool = false,
        enabled: Bool = true, logo: Int = 0, now: ChannelProgram? = nil, next: ChannelProgram? = nil
    ) {
        self.id = id
        self.number = number
        self.name = name
        self.category = category
        self.personal = personal
        self.auto = auto
        self.enabled = enabled
        self.logo = logo
        self.now = now
        self.next = next
    }

    enum CodingKeys: String, CodingKey {
        case id, number, name, category, personal, auto, enabled, logo, now, next
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        number = c.value(.number, default: 0)
        name = c.value(.name, default: "")
        category = c.value(.category, default: "")
        personal = c.value(.personal, default: false)
        auto = c.value(.auto, default: false)
        enabled = c.value(.enabled, default: true)
        logo = c.value(.logo, default: 0)
        now = c.optional(.now)
        next = c.optional(.next)
    }

    /// The logo's gradient. Out-of-range indexes wrap, so every channel gets a colour.
    public var logoPreset: AvatarPreset {
        let presets = Array(AvatarPreset.allCases.prefix(7))
        return presets[((logo % presets.count) + presets.count) % presets.count]
    }

    /// What is on at `date`: `now`, or `next` once `now` has ended (the list is refreshed
    /// only every half minute), else `now` as last known.
    public func program(at date: Date) -> ChannelProgram? {
        if let now, now.isOnAir(at: date) { return now }
        if let next, next.isOnAir(at: date) { return next }
        return now
    }

    /// The channel `step` places away by number (+1 is channel up), wrapping around the
    /// ends of the list. `channels` need not be sorted. nil when `id` is not in the list.
    public static func neighbour(of id: Int, in channels: [Channel], step: Int) -> Channel? {
        let sorted = channels.sorted { ($0.number, $0.id) < ($1.number, $1.id) }
        guard let index = sorted.firstIndex(where: { $0.id == id }), !sorted.isEmpty else { return nil }
        let count = sorted.count
        return sorted[((index + step) % count + count) % count]
    }
}

/// A programme of a channel: a movie or an episode with its slot on air.
public struct ChannelProgram: Decodable, Hashable, Sendable {
    public var itemId: Int
    public var title: String
    /// Episodes: "S1 E5 · Episode 5".
    public var subtitle: String
    public var overview: String
    public var year: Int?
    public var start: Date
    public var end: Date
    public var poster: String
    public var backdrop: String

    public init(
        itemId: Int, title: String, subtitle: String = "", overview: String = "", year: Int? = nil,
        start: Date, end: Date, poster: String = "", backdrop: String = ""
    ) {
        self.itemId = itemId
        self.title = title
        self.subtitle = subtitle
        self.overview = overview
        self.year = year
        self.start = start
        self.end = end
        self.poster = poster
        self.backdrop = backdrop
    }

    enum CodingKeys: String, CodingKey {
        case itemId, title, subtitle, overview, year, start, end, poster, backdrop
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        itemId = c.value(.itemId, default: 0)
        title = c.value(.title, default: "")
        subtitle = c.value(.subtitle, default: "")
        overview = c.value(.overview, default: "")
        year = c.optional(.year)
        start = Timestamp.parse(c.optional(.start)) ?? Date(timeIntervalSince1970: 0)
        end = Timestamp.parse(c.optional(.end)) ?? Date(timeIntervalSince1970: 0)
        poster = c.value(.poster, default: "")
        backdrop = c.value(.backdrop, default: "")
    }

    /// How far the programme is at `date`, 0…1 (0 for a slot without a length).
    public func progress(at date: Date) -> Double {
        let length = end.timeIntervalSince(start)
        guard length > 0 else { return 0 }
        return min(1, max(0, date.timeIntervalSince(start) / length))
    }

    /// `start` ≤ `date` < `end`.
    public func isOnAir(at date: Date) -> Bool {
        start <= date && date < end
    }

    /// The title with the episode line: "Show · S1 E5 · Episode 5".
    public var fullTitle: String {
        subtitle.isEmpty ? title : "\(title) · \(subtitle)"
    }
}

/// `GET /api/channels`.
public struct ChannelList: Decodable, Hashable, Sendable {
    public var channels: [Channel]
    /// The profile may manage channels (web only).
    public var canManage: Bool
    public var canCreate: Bool

    public init(channels: [Channel], canManage: Bool = false, canCreate: Bool = false) {
        self.channels = channels
        self.canManage = canManage
        self.canCreate = canCreate
    }

    enum CodingKeys: String, CodingKey { case channels, canManage, canCreate }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        channels = c.value(.channels, default: [])
        canManage = c.value(.canManage, default: false)
        canCreate = c.value(.canCreate, default: false)
    }
}

/// `GET /api/channels/{id}/guide`: the channel and its programmes from the one on air on.
public struct ChannelGuide: Decodable, Hashable, Sendable {
    public var channel: Channel
    public var programs: [ChannelProgram]

    public init(channel: Channel, programs: [ChannelProgram]) {
        self.channel = channel
        self.programs = programs
    }

    enum CodingKeys: String, CodingKey { case channel, programs }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        channel = try c.decode(Channel.self, forKey: .channel)
        programs = c.value(.programs, default: [])
    }

    /// The programme on air at `date` and the one after it. Between refreshes the guide
    /// moves on by itself; before its first programme nothing is on yet and the first is next.
    public func onAir(at date: Date) -> (now: ChannelProgram?, next: ChannelProgram?) {
        let sorted = programs.sorted { $0.start < $1.start }
        if let index = sorted.firstIndex(where: { $0.isOnAir(at: date) }) {
            return (sorted[index], index + 1 < sorted.count ? sorted[index + 1] : nil)
        }
        return (nil, sorted.first { $0.start > date })
    }
}

/// A section of the TV tab: the channels of one category.
public struct ChannelSection: Hashable, Identifiable, Sendable {
    public var category: String
    public var channels: [Channel]

    public var id: String { category }

    public init(category: String, channels: [Channel]) {
        self.category = category
        self.channels = channels
    }

    /// The channels by category: sections in the order of their lowest channel number,
    /// channels inside by number (as the web app's `byCategory`).
    public static func group(_ channels: [Channel]) -> [ChannelSection] {
        var sections: [ChannelSection] = []
        var index: [String: Int] = [:]
        for channel in channels.sorted(by: { ($0.number, $0.id) < ($1.number, $1.id) }) {
            if let i = index[channel.category] {
                sections[i].channels.append(channel)
            } else {
                index[channel.category] = sections.count
                sections.append(ChannelSection(category: channel.category, channels: [channel]))
            }
        }
        return sections
    }
}
