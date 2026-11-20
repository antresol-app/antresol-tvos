import Foundation

/// How the live stream on screen reaches the Apple TV, for the banner's quiet line:
/// «Напрямую · provider.example» (the provider's URL, played as given), «Через Antresol»
/// (an own channel, or the server's hidden-address redirect), then the stream's format,
/// its video and audio codecs where known, and «Источник 2 из 3» when there are fallbacks.
public struct LivePlaybackPath: Equatable, Sendable {
    public enum Route: Equatable, Sendable {
        /// The provider's own URL: its host (never the rest of it, which may carry credentials).
        case direct(host: String)
        /// An own channel, or an external one behind the server's redirect.
        case antresol
    }

    public var route: Route
    /// "HLS", "MPEG-TS" or nil.
    public var format: String?
    /// "H.264", "HEVC"… or nil.
    public var video: String?
    /// "AAC", "AC-3", "MP2"… or nil.
    public var audio: String?
    /// The source tried (1-based) and how many there are; nil for own channels.
    public var attempt: Int?
    public var count: Int?

    public init(route: Route, format: String? = nil, video: String? = nil, audio: String? = nil, attempt: Int? = nil, count: Int? = nil) {
        self.route = route
        self.format = format
        self.video = video
        self.audio = audio
        self.attempt = attempt
        self.count = count
    }

    /// An external source's path: the host of a provider URL, or the server's redirect.
    public static func external(_ source: StreamSource, attempt: Int, count: Int) -> LivePlaybackPath {
        let route: Route
        if source.isServerPath {
            route = .antresol
        } else {
            route = .direct(host: URL(string: source.url)?.host ?? "")
        }
        return LivePlaybackPath(route: route, format: formatName(source.format, url: source.url), attempt: attempt + 1, count: count)
    }

    /// The format's name: the server's word, else the URL's extension (nil: unknown).
    public static func formatName(_ format: String, url: String) -> String? {
        switch format.lowercased() {
        case "hls": return "HLS"
        case "ts": return "MPEG-TS"
        default: break
        }
        let path = URL(string: url)?.path.lowercased() ?? ""
        if path.hasSuffix(".m3u8") || path.hasSuffix(".m3u") { return "HLS" }
        if path.hasSuffix(".ts") { return "MPEG-TS" }
        return nil
    }

    /// The parts after the route, in order: format, "video · audio", the source count.
    /// The route and «Источник n из m» are the app's (localised) words.
    public var technical: [String] {
        var parts: [String] = []
        if let format { parts.append(format) }
        let codecs = [video, audio].compactMap { $0 }
        if !codecs.isEmpty { parts.append(codecs.joined(separator: " / ")) }
        return parts
    }

    /// «Источник n из m» is worth showing: there is more than one source.
    public var showsAttempt: Bool { (count ?? 0) > 1 && attempt != nil }
}

/// Codec names for people: from a sample description's four-character code
/// (`CMFormatDescription` media subtype) or an HLS `CODECS` entry ("avc1.64001f").
public enum MediaCodecName {
    public static func name(fourCC: String) -> String? {
        let code = fourCC.trimmingCharacters(in: .whitespaces).lowercased()
        switch code {
        case "avc1", "avc3": return "H.264"
        case "hvc1", "hev1": return "HEVC"
        case "dvh1", "dvhe": return "Dolby Vision"
        case "av01": return "AV1"
        case "vp09": return "VP9"
        case "mp4a", "aac", "aach", "aacl": return "AAC"
        case "ac-3", "ac3": return "AC-3"
        case "ec-3", "ec3": return "E-AC-3"
        case "ac-4": return "AC-4"
        case ".mp3", "mp3": return "MP3"
        case ".mp2", "mp2", "mp2a", "mpga": return "MP2"
        case "dts", "dtsc", "dtsh", "dtsl", "dtse": return "DTS"
        case "opus": return "Opus"
        case "flac", "fla": return "FLAC"
        case "alac": return "ALAC"
        case "lpcm", "sowt", "twos": return "PCM"
        default: return nil
        }
    }

    /// One `CODECS` entry: its four-character code is everything before the first dot;
    /// AAC's object type `mp4a.40.x` is AAC, `mp4a.6b` / `mp4a.69` are MP3 / MP2-style audio.
    public static func name(hlsCodec: String) -> String? {
        let codec = hlsCodec.trimmingCharacters(in: .whitespaces).lowercased()
        if codec == "mp4a.6b" || codec == "mp4a.69" { return "MP3" }
        let code = codec.split(separator: ".").first.map(String.init) ?? codec
        return name(fourCC: code)
    }

    /// Whether Apple TV decodes this audio (AVFoundation does not play MP2 or DTS).
    public static func isPlayableAudio(_ name: String) -> Bool {
        !["MP2", "DTS"].contains(name)
    }
}

/// The codecs a master playlist names (`EXT-X-STREAM-INF` `CODECS`), of its first variant:
/// the first video and the first audio codec, nil when it does not say.
public struct StreamCodecs: Equatable, Sendable {
    public var video: String?
    public var audio: String?

    public init(video: String? = nil, audio: String? = nil) {
        self.video = video
        self.audio = audio
    }

    public init(master: String) {
        self.init()
        for raw in master.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("#EXT-X-STREAM-INF:") else { continue }
            let attrs = LiveRenditions.attributes(String(line.dropFirst("#EXT-X-STREAM-INF:".count)))
            guard let codecs = attrs["CODECS"], !codecs.isEmpty else { continue }
            for entry in codecs.split(separator: ",") {
                guard let name = MediaCodecName.name(hlsCodec: String(entry)) else { continue }
                if Self.videoNames.contains(name) {
                    if video == nil { video = name }
                } else if audio == nil {
                    audio = name
                }
            }
            return
        }
    }

    public init(master data: Data) {
        self.init(master: String(decoding: data, as: UTF8.self))
    }

    static let videoNames: Set<String> = ["H.264", "HEVC", "Dolby Vision", "AV1", "VP9"]
}

/// The sources of an external channel that did not play well on this device (an error, no
/// sound, a long stall), kept per channel for a few days: the player tries them last. Only a
/// digest of the URL is stored (a provider's may carry credentials). Never sent anywhere.
public struct ExternalSourceMemory {
    private let defaults: UserDefaults
    private let prefix: String
    /// How long a bad mark holds.
    public static let lifetime: TimeInterval = 3 * 24 * 3600

    public init(defaults: UserDefaults = .standard, prefix: String = "tv.external.badSources.") {
        self.defaults = defaults
        self.prefix = prefix
    }

    /// The sources in the order to try them: the good ones as they are, then the ones marked bad
    /// (in their own order).
    public func ordered(_ sources: [StreamSource], channel: Int, now: Date = Date()) -> [StreamSource] {
        let bad = marks(channel, now: now)
        guard !bad.isEmpty else { return sources }
        let isBad = { (s: StreamSource) in bad[Self.digest(s.url)] != nil }
        return sources.filter { !isBad($0) } + sources.filter(isBad)
    }

    public func isBad(_ source: StreamSource, channel: Int, now: Date = Date()) -> Bool {
        marks(channel, now: now)[Self.digest(source.url)] != nil
    }

    public func markBad(_ source: StreamSource, channel: Int, now: Date = Date()) {
        var m = marks(channel, now: now)
        m[Self.digest(source.url)] = now.timeIntervalSince1970
        store(m, channel)
    }

    /// A source that played with sound loses its mark.
    public func markGood(_ source: StreamSource, channel: Int, now: Date = Date()) {
        var m = marks(channel, now: now)
        guard m.removeValue(forKey: Self.digest(source.url)) != nil else { return }
        store(m, channel)
    }

    private func marks(_ channel: Int, now: Date) -> [String: Double] {
        guard let stored = defaults.dictionary(forKey: prefix + String(channel)) as? [String: Double] else { return [:] }
        return stored.filter { now.timeIntervalSince1970 - $0.value < Self.lifetime }
    }

    private func store(_ marks: [String: Double], _ channel: Int) {
        if marks.isEmpty {
            defaults.removeObject(forKey: prefix + String(channel))
        } else {
            defaults.set(marks, forKey: prefix + String(channel))
        }
    }

    /// FNV-1a 64 of the URL, hex: stable across launches, not reversible to the URL.
    static func digest(_ url: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in url.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return String(hash, radix: 16)
    }
}

/// What an external channel does next when a source fails or plays without sound: the next
/// source; when none is left, the first source that did play (silent) with a note rather than
/// nothing; else the failure message.
public enum ExternalFallback {
    public enum Step: Equatable, Sendable {
        case tryNext(Int)
        /// Play this source although it has no sound the device plays, and say so.
        case acceptSilent(Int)
        case giveUp
    }

    /// Source `attempt` (0-based) of `count` failed; `silent` are the attempts that played without sound.
    public static func afterFailure(attempt: Int, count: Int, silent: Set<Int>) -> Step {
        if attempt + 1 < count { return .tryNext(attempt + 1) }
        if let first = silent.filter({ $0 != attempt }).min() { return .acceptSilent(first) }
        return .giveUp
    }

    /// Source `attempt` plays but without sound: the next one, else keep this one (silent).
    public static func afterSilence(attempt: Int, count: Int) -> Step {
        attempt + 1 < count ? .tryNext(attempt + 1) : .acceptSilent(attempt)
    }
}
