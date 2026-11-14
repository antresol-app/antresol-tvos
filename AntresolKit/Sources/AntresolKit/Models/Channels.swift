import Foundation

/// A live channel made of the library (`GET /api/channels`, «ТВ»). The server plays its
/// programmes back to back; apps list channels, show what is on, keep favourites and play
/// the live stream. A channel is its number and its name, with the logo someone uploaded
/// when there is one (`logoUrl`; the server's generated `logo` index is for IPTV players and
/// is not decoded); its picture is the programme on air.
/// Editing (`rules`) is web only and not decoded.
public struct Channel: Decodable, Hashable, Identifiable, Sendable {
    public var id: Int
    /// The channel number: the order of the one list and of channel up / down.
    public var number: Int
    /// In the viewer's language (the server translates generated names).
    public var name: String
    /// The theme the channel belongs to: a filter of the list, nothing more.
    public var category: String
    /// One of the profile's favourites (per profile, on the server).
    public var favorite: Bool
    public var personal: Bool
    public var auto: Bool
    public var enabled: Bool
    /// What is on air, when the server knows.
    public var now: ChannelProgram?
    public var next: ChannelProgram?
    /// The uploaded logo (`/api/channels/{id}/logo.png?v=…`); "" when there is none.
    public var logoUrl: String
    /// A channel of an admin's external source (M3U / Xtream): the app plays `stream`
    /// itself; its programmes have no item page.
    public var external: Bool
    /// How to play an external channel (nil for the server's own channels).
    public var stream: ChannelStream?

    public init(
        id: Int, number: Int, name: String, category: String = "", favorite: Bool = false, personal: Bool = false,
        auto: Bool = false, enabled: Bool = true, now: ChannelProgram? = nil, next: ChannelProgram? = nil,
        logoUrl: String = "", external: Bool = false, stream: ChannelStream? = nil
    ) {
        self.logoUrl = logoUrl
        self.external = external || stream != nil
        self.stream = stream
        self.id = id
        self.number = number
        self.name = name
        self.category = category
        self.favorite = favorite
        self.personal = personal
        self.auto = auto
        self.enabled = enabled
        self.now = now
        self.next = next
    }

    enum CodingKeys: String, CodingKey {
        case id, number, name, category, favorite, personal, auto, enabled, now, next, logoUrl, external, stream
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        number = c.value(.number, default: 0)
        name = c.value(.name, default: "")
        category = c.value(.category, default: "")
        favorite = c.value(.favorite, default: false)
        personal = c.value(.personal, default: false)
        auto = c.value(.auto, default: false)
        enabled = c.value(.enabled, default: true)
        now = c.optional(.now)
        next = c.optional(.next)
        logoUrl = c.value(.logoUrl, default: "")
        stream = c.optional(.stream)
        external = c.value(.external, default: false) || stream != nil
    }

    /// What is on at `date`: `now`, or `next` once `now` has ended (the list is refreshed
    /// only every half minute), else `now` as last known.
    public func program(at date: Date) -> ChannelProgram? {
        if let now, now.isOnAir(at: date) { return now }
        if let next, next.isOnAir(at: date) { return next }
        return now
    }

    /// What comes after the programme on air at `date` («Далее 21:40 …»): `next`, unless
    /// it is already on air or over (the list is refreshed only every half minute).
    public func upNext(at date: Date) -> ChannelProgram? {
        guard let next, next != program(at: date), next.end > date else { return nil }
        return next
    }

    /// The channel `step` places away by number (+1 is channel up), wrapping around the
    /// ends of the list. `channels` need not be sorted. nil when `id` is not in the list.
    public static func neighbour(of id: Int, in channels: [Channel], step: Int) -> Channel? {
        let sorted = channels.sorted(by: Channel.byNumber)
        guard let index = sorted.firstIndex(where: { $0.id == id }), !sorted.isEmpty else { return nil }
        let count = sorted.count
        return sorted[((index + step) % count + count) % count]
    }

    /// The list's order: by number, then id.
    public static func byNumber(_ a: Channel, _ b: Channel) -> Bool {
        (a.number, a.id) < (b.number, b.id)
    }
}

/// An audio or subtitle rendition a programme really has (`Program.audio` / `.subtitles`):
/// `name` is that rendition's HLS `NAME` (unique within its kind: what the player selects
/// and remembers), `label` what the picker shows («Русский — LostFilm»). `slot` is the
/// server's key for it, informational only (older servers sent fixed `ru`, `ru2`, `en`,
/// `orig`); a stream may carry any number of renditions with any names.
public struct LiveTrack: Decodable, Hashable, Sendable, Identifiable {
    public var slot: String
    public var name: String
    public var label: String
    public var lang: String
    /// A cleaned voice-over: the `name` of the voice-over it is the cleaned
    /// version of in this programme (nil: none).
    public var cleanedOf: String?

    public var id: String { name }

    public init(slot: String = "", name: String, label: String = "", lang: String = "", cleanedOf: String? = nil) {
        self.slot = slot.isEmpty ? name : slot
        self.name = name
        self.label = label
        self.lang = lang
        self.cleanedOf = cleanedOf
    }

    enum CodingKeys: String, CodingKey { case slot, name, label, lang, cleanedOf }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let slot: String = c.value(.slot, default: "")
        let name: String = c.value(.name, default: "")
        self.name = name.isEmpty ? slot : name
        self.slot = slot.isEmpty ? self.name : slot
        label = c.value(.label, default: "")
        lang = c.value(.lang, default: "")
        let of: String = c.value(.cleanedOf, default: "")
        cleanedOf = of.isEmpty ? nil : of
    }

    /// What the picker shows: the label, else the rendition's name.
    public var title: String {
        label.isEmpty ? name : label
    }

    /// The picker's two parts: the voice and, apart, its language («Русский — LostFilm» →
    /// «LostFilm», «Русский»); a label without « — » is the voice alone.
    public var voiceAndLanguage: (voice: String, language: String?) {
        let parts = title.components(separatedBy: " — ")
        guard parts.count >= 2, let first = parts.first, !first.isEmpty else { return (title, nil) }
        let rest = parts.dropFirst().joined(separator: " — ")
        return rest.isEmpty ? (title, nil) : (rest, first)
    }
}

/// A programme of a channel: a movie or an episode with its slot on air.
public struct ChannelProgram: Decodable, Hashable, Sendable {
    /// "<channel>-<seq>"; "" from servers before the guide grid.
    public var id: String
    public var itemId: Int
    /// "movie" or "episode".
    public var kind: String
    public var title: String
    /// Episodes: "S1 E5 · Episode 5".
    public var subtitle: String
    public var overview: String
    public var year: Int?
    /// The age rating ("12+").
    public var rating: String
    public var genres: [String]
    public var start: Date
    public var end: Date
    public var poster: String
    public var backdrop: String
    /// Not from the library (an online extra).
    public var external: Bool
    /// The audio renditions the programme has; nil when unknown, empty when none.
    public var audio: [LiveTrack]?
    /// The subtitle renditions the programme has; nil when unknown, empty when none.
    public var subtitles: [LiveTrack]?

    public init(
        id: String = "", itemId: Int, kind: String = "movie", title: String, subtitle: String = "", overview: String = "",
        year: Int? = nil, rating: String = "", genres: [String] = [], start: Date, end: Date, poster: String = "",
        backdrop: String = "", external: Bool = false, audio: [LiveTrack]? = nil, subtitles: [LiveTrack]? = nil
    ) {
        self.id = id
        self.itemId = itemId
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.overview = overview
        self.year = year
        self.rating = rating
        self.genres = genres
        self.start = start
        self.end = end
        self.poster = poster
        self.backdrop = backdrop
        self.external = external
        self.audio = audio
        self.subtitles = subtitles
    }

    enum CodingKeys: String, CodingKey {
        case id, itemId, kind, title, subtitle, overview, year, rating, genres, start, end, poster, backdrop, external
        case audio, subtitles
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.value(.id, default: "")
        itemId = c.value(.itemId, default: 0)
        kind = c.value(.kind, default: "")
        title = c.value(.title, default: "")
        subtitle = c.value(.subtitle, default: "")
        overview = c.value(.overview, default: "")
        year = c.optional(.year)
        rating = c.value(.rating, default: "")
        genres = c.value(.genres, default: [])
        start = Timestamp.parse(c.optional(.start)) ?? Date(timeIntervalSince1970: 0)
        end = Timestamp.parse(c.optional(.end)) ?? Date(timeIntervalSince1970: 0)
        poster = c.value(.poster, default: "")
        backdrop = c.value(.backdrop, default: "")
        external = c.value(.external, default: false)
        audio = c.optional(.audio)
        subtitles = c.optional(.subtitles)
    }

    /// A key that tells programmes apart even on servers without `id`.
    public var key: String {
        id.isEmpty ? "\(itemId)@\(start.timeIntervalSince1970)" : id
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

    /// The picture of the programme: its backdrop, else its poster, else "" (the clients
    /// draw a neutral placeholder).
    public var still: String {
        backdrop.isEmpty ? poster : backdrop
    }
}

/// `GET /api/channels`.
public struct ChannelList: Decodable, Hashable, Sendable {
    /// The one list, by number.
    public var channels: [Channel]
    /// The channel the profile tuned in last (`PUT /api/channels/last`), if any.
    public var lastChannel: Int?
    /// The profile may manage channels (web only).
    public var canManage: Bool
    public var canCreate: Bool

    public init(channels: [Channel], lastChannel: Int? = nil, canManage: Bool = false, canCreate: Bool = false) {
        self.channels = channels
        self.lastChannel = lastChannel
        self.canManage = canManage
        self.canCreate = canCreate
    }

    enum CodingKeys: String, CodingKey { case channels, lastChannel, canManage, canCreate }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        channels = (c.value(.channels, default: [Channel]())).sorted(by: Channel.byNumber)
        lastChannel = c.optional(.lastChannel)
        canManage = c.value(.canManage, default: false)
        canCreate = c.value(.canCreate, default: false)
    }

    /// The last channel as the list has it, or nil when there is none or the profile no
    /// longer sees it.
    public var last: Channel? {
        guard let lastChannel else { return nil }
        return channels.first { $0.id == lastChannel }
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
