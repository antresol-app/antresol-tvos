import Foundation

// «ТВ» external channels (an admin's M3U / Xtream source on the server): the app plays the
// provider's stream itself; the server never touches the video.

/// One way to play an external channel: the provider's URL with the headers its playlist
/// asked for (user-agent / referrer), or the server's redirect
/// (`/api/channels/live/ext/{id}/{n}`) when the source hides provider addresses.
public struct StreamSource: Decodable, Hashable, Sendable {
    public var url: String
    public var userAgent: String
    public var referrer: String
    /// The platforms that cannot play it as given ("web", or an app's platform tag).
    public var unsupported: [String]
    /// What the stream is, by the server: "hls", "ts" (a raw MPEG-TS stream) or "" (unknown).
    public var format: String
    /// The web's same-origin relay of the stream (a path); the apps keep `url` and only show
    /// that it exists.
    public var relay: String

    public init(url: String, userAgent: String = "", referrer: String = "", unsupported: [String] = [], format: String = "", relay: String = "") {
        self.url = url
        self.userAgent = userAgent
        self.referrer = referrer
        self.unsupported = unsupported
        self.format = format
        self.relay = relay
    }

    enum CodingKeys: String, CodingKey { case url, userAgent, referrer, unsupported, format, relay }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        url = try c.decode(String.self, forKey: .url)
        userAgent = c.value(.userAgent, default: "")
        referrer = c.value(.referrer, default: "")
        unsupported = c.value(.unsupported, default: [String]())
        format = c.value(.format, default: "")
        relay = c.value(.relay, default: "")
    }

    /// The server's own redirect (a path): it needs the app's media key like every other
    /// media URL. A provider URL never gets it.
    public var isServerPath: Bool { url.hasPrefix("/") }

    /// The HTTP headers the player sends (AVURLAsset options).
    public var headers: [String: String] {
        var h: [String: String] = [:]
        if !userAgent.isEmpty { h["User-Agent"] = userAgent }
        if !referrer.isEmpty { h["Referer"] = referrer }
        return h
    }

    public func isUnsupported(on tags: Set<String>) -> Bool {
        unsupported.contains { tags.contains($0.lowercased()) }
    }
}

/// `channel.stream`: the primary source and its fallbacks in order.
public struct ChannelStream: Decodable, Hashable, Sendable {
    public var primary: StreamSource
    public var fallbacks: [StreamSource]

    public init(primary: StreamSource, fallbacks: [StreamSource] = []) {
        self.primary = primary
        self.fallbacks = fallbacks
    }

    enum CodingKeys: String, CodingKey { case fallbacks }

    public init(from decoder: Decoder) throws {
        primary = try StreamSource(from: decoder)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        fallbacks = c.value(.fallbacks, default: [StreamSource]())
    }

    public var sources: [StreamSource] { [primary] + fallbacks }

    /// The sources this platform plays, in the order the player tries them.
    public func playable(on tags: Set<String>) -> [StreamSource] {
        sources.filter { !$0.isUnsupported(on: tags) }
    }

    /// The tags `unsupported` may name for this app.
    public static let tvOSTags: Set<String> = ["tvos", "apple"]
}

extension ServerURLs {
    /// The URL the player opens for an external source: the provider's own as given, or
    /// the server's redirect with the media key. nil for anything else.
    public func externalStream(_ source: StreamSource, mediaKey: String?) -> URL? {
        if source.isServerPath { return url(path: source.url, query: Self.mediaKeyQuery(mediaKey)) }
        guard let u = URL(string: source.url), let scheme = u.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
        return u
    }
}

/// The voice and subtitles the viewer picked on an external channel, kept on this device
/// per channel (never sent to the server), by the stream's own names with their language.
/// Nothing kept: the profile's languages.
public struct ExternalTrackMemory {
    private let defaults: UserDefaults
    private let prefix: String

    public init(defaults: UserDefaults = .standard, prefix: String = "tv.external.tracks.") {
        self.defaults = defaults
        self.prefix = prefix
    }

    struct Stored: Codable, Equatable {
        struct Pick: Codable, Equatable { var name: String; var lang: String }
        var audio: Pick?
        var subtitles: Pick?
        var subtitlesOff: Bool?
    }

    public func selection(for channel: Int) -> LiveTrackSelection {
        guard let data = defaults.data(forKey: prefix + String(channel)),
              let s = try? JSONDecoder().decode(Stored.self, from: data) else { return LiveTrackSelection() }
        var out = LiveTrackSelection()
        out.audio = s.audio.map { .init(name: $0.name, lang: $0.lang) }
        if s.subtitlesOff == true {
            out.subtitle = .some(nil)
        } else if let p = s.subtitles {
            out.subtitle = .some(.init(name: p.name, lang: p.lang))
        }
        return out
    }

    public func save(_ selection: LiveTrackSelection, for channel: Int) {
        var s = Stored()
        s.audio = selection.audio.map { .init(name: $0.name, lang: $0.lang) }
        switch selection.subtitle {
        case .none: break
        case .some(.none): s.subtitlesOff = true
        case .some(.some(let p)): s.subtitles = .init(name: p.name, lang: p.lang)
        }
        guard let data = try? JSONEncoder().encode(s) else { return }
        defaults.set(data, forKey: prefix + String(channel))
    }
}

/// The audio / subtitle entries of an external stream: the stream's own names (the
/// master's `EXT-X-MEDIA` NAME where it can be told, else the option's), one per option,
/// `slot` = `o<index>` in its group; two options of one name become «English», «English 2».
public enum ExternalTracks {
    public static func entries(options: [(name: String, lang: String)], renditions: [HLSRendition]) -> [LiveTrack] {
        var seen: [String: Int] = [:]
        return options.enumerated().map { i, o in
            let base = LiveRenditions.name(ofOption: i, options: options, renditions: renditions) ?? o.name
            let named = base.isEmpty ? (o.lang.isEmpty ? "\(i + 1)" : o.lang) : base
            let n = (seen[named] ?? 0) + 1
            seen[named] = n
            let name = n == 1 ? named : "\(named) \(n)"
            return LiveTrack(slot: "o\(i)", name: name, label: name, lang: o.lang)
        }
    }

    public static func index(of track: LiveTrack) -> Int? {
        guard track.slot.hasPrefix("o") else { return nil }
        return Int(track.slot.dropFirst())
    }
}
