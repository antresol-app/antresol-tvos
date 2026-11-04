import Foundation

/// Decoder capabilities sent with `/api/play` (§5.1). Omitting them makes the
/// server transcode everything.
public struct DeviceCaps: Codable, Hashable, Sendable {
    public var videoCodecs: [String]
    public var audioCodecs: [String]
    public var containers: [String]
    public var maxHeight: Int?
    /// Bits per second; 0 means no cap.
    public var maxBitrate: Int?
    /// Repackage `hev1`-tagged HEVC as `hvc1` (needed by Apple players).
    public var hevcNeedsHvc1: Bool?

    public init(
        videoCodecs: [String], audioCodecs: [String], containers: [String],
        maxHeight: Int? = nil, maxBitrate: Int? = nil, hevcNeedsHvc1: Bool? = nil
    ) {
        self.videoCodecs = videoCodecs
        self.audioCodecs = audioCodecs
        self.containers = containers
        self.maxHeight = maxHeight
        self.maxBitrate = maxBitrate
        self.hevcNeedsHvc1 = hevcNeedsHvc1
    }

    /// AVPlayer on Apple TV. Pass `av1: true` only on hardware that decodes AV1.
    public static func appleTV(maxHeight: Int = 2160, av1: Bool = false) -> DeviceCaps {
        DeviceCaps(
            videoCodecs: av1 ? ["h264", "hevc", "av1"] : ["h264", "hevc"],
            audioCodecs: ["aac", "ac3", "eac3"],
            containers: ["mp4", "mov"],
            maxHeight: maxHeight,
            maxBitrate: 0,
            hevcNeedsHvc1: true
        )
    }
}

/// Quality presets of `/api/play`.
public enum VideoQuality: String, CaseIterable, Codable, Sendable {
    case auto
    /// No quality cap (does not force direct play).
    case original
    case p1080 = "1080"
    case p720 = "720"
    case p480 = "480"
}

/// Body of `POST /api/play/{fileId}`.
public struct PlayRequest: Encodable, Hashable, Sendable {
    public var caps: DeviceCaps
    public var startSec: Double?
    public var quality: VideoQuality?
    public var audioIndex: Int?
    /// HLS session to replace (seek outside the window, audio or quality change).
    public var replaceSession: String?
    /// Image subtitle index to burn in.
    public var burnSubtitle: Int?

    public init(
        caps: DeviceCaps, startSec: Double? = nil, quality: VideoQuality? = nil,
        audioIndex: Int? = nil, replaceSession: String? = nil, burnSubtitle: Int? = nil
    ) {
        self.caps = caps
        self.startSec = startSec
        self.quality = quality
        self.audioIndex = audioIndex
        self.replaceSession = replaceSession
        self.burnSubtitle = burnSubtitle
    }
}

/// How the server delivers a video.
public struct PlaybackMode: RawRepresentable, Codable, Hashable, Sendable, ExpressibleByStringLiteral {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        self.rawValue = value
    }

    /// Progressive file with Range support at `/api/stream/{fileId}`.
    public static let direct: PlaybackMode = "direct"
    /// HLS, video copied, container or audio converted.
    public static let remux: PlaybackMode = "remux"
    /// HLS, video re-encoded.
    public static let transcode: PlaybackMode = "transcode"

    public var isHLS: Bool {
        self == .remux || self == .transcode
    }
}

public struct PlayQuality: Decodable, Hashable, Sendable {
    /// What the client asked for.
    public var selected: String
    /// What is used (`original`, `1080`, ...).
    public var applied: String
    /// The remote quality cap is in effect.
    public var remote: Bool

    public init(selected: String = "auto", applied: String = "original", remote: Bool = false) {
        self.selected = selected
        self.applied = applied
        self.remote = remote
    }

    enum CodingKeys: String, CodingKey { case selected, applied, remote }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        selected = c.value(.selected, default: "auto")
        applied = c.value(.applied, default: "original")
        remote = c.value(.remote, default: false)
    }
}

/// Response of `POST /api/play/{fileId}`.
public struct PlayResponse: Decodable, Hashable, Sendable {
    public var mode: PlaybackMode
    /// `/api/stream/{fileId}` or `/api/hls/{session}/index.m3u8`.
    public var url: String
    /// Localized reason why playback is not direct; `""` for direct play.
    public var reason: String
    /// Effective start. For HLS, playlist time 0 equals this file position.
    public var startSec: Double
    public var durationMs: Int
    public var audioIndex: Int
    public var audio: [AudioTrack]
    public var subtitles: [SubtitleTrack]
    public var quality: PlayQuality
    /// A complete VOD playlist is served when requested with a media key.
    public var hlsComplete: Bool
    public var burnedSubtitle: Int?

    enum CodingKeys: String, CodingKey {
        case mode, url, reason, startSec, durationMs, audioIndex, audio, subtitles, quality
        case hlsComplete, burnedSubtitle
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mode = c.value(.mode, default: .direct)
        url = try c.decode(String.self, forKey: .url)
        reason = c.value(.reason, default: "")
        startSec = c.value(.startSec, default: 0)
        durationMs = c.value(.durationMs, default: 0)
        audioIndex = c.value(.audioIndex, default: 0)
        audio = c.value(.audio, default: [])
        subtitles = c.value(.subtitles, default: [])
        quality = c.value(.quality, default: PlayQuality())
        hlsComplete = c.value(.hlsComplete, default: false)
        burnedSubtitle = c.optional(.burnedSubtitle)
    }

    /// The HLS session id parsed from `url`, nil for direct play.
    public var hlsSessionID: String? {
        HLSSessionID.parse(url)
    }
}

/// Extracts `{session}` from `/api/hls/{session}/index.m3u8`.
public enum HLSSessionID {
    public static func parse(_ url: String) -> String? {
        let path = url.split(separator: "?", maxSplits: 1).first.map(String.init) ?? url
        let parts = path.split(separator: "/").map(String.init)
        guard let hls = parts.lastIndex(of: "hls"), hls + 1 < parts.count, parts[hls - 1] == "api" else {
            return nil
        }
        let session = parts[hls + 1]
        return session.isEmpty ? nil : session
    }
}

/// Response of `PUT /api/hls/{session}`.
public struct HLSStatus: Decodable, Hashable, Sendable {
    public var segments: Int
    public var running: Bool
    public var paused: Bool

    enum CodingKeys: String, CodingKey { case segments, running, paused }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        segments = c.value(.segments, default: 0)
        running = c.value(.running, default: false)
        paused = c.value(.paused, default: false)
    }
}

/// `GET /api/progress/{itemId}`.
public struct PlaybackProgress: Decodable, Hashable, Sendable {
    /// For audiobooks: position on the whole-book timeline.
    public var positionMs: Int
    public var durationMs: Int
    public var finished: Bool
    /// Reader position for books and comics, e.g. "page:2".
    public var locator: String
    public var fraction: Double
    /// nil when there is no progress yet.
    public var updatedAt: String?

    public init(
        positionMs: Int = 0, durationMs: Int = 0, finished: Bool = false, locator: String = "",
        fraction: Double = 0, updatedAt: String? = nil
    ) {
        self.positionMs = positionMs
        self.durationMs = durationMs
        self.finished = finished
        self.locator = locator
        self.fraction = fraction
        self.updatedAt = updatedAt
    }

    enum CodingKeys: String, CodingKey { case positionMs, durationMs, finished, locator, fraction, updatedAt }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        positionMs = c.value(.positionMs, default: 0)
        durationMs = c.value(.durationMs, default: 0)
        finished = c.value(.finished, default: false)
        locator = c.value(.locator, default: "")
        fraction = c.value(.fraction, default: 0)
        updatedAt = c.optional(.updatedAt)
    }

    public var exists: Bool {
        updatedAt != nil
    }
}

/// Body of `PUT /api/progress/{itemId}`: either a media position or a reader position.
public struct ProgressUpdate: Encodable, Hashable, Sendable {
    public var positionMs: Int?
    public var durationMs: Int?
    public var locator: String?
    public var fraction: Double?
    /// When the position was recorded on the client; older writes are ignored by the server.
    public var updatedAt: String?

    public init(
        positionMs: Int? = nil, durationMs: Int? = nil, locator: String? = nil,
        fraction: Double? = nil, updatedAt: Date? = nil
    ) {
        self.positionMs = positionMs
        self.durationMs = durationMs
        self.locator = locator
        self.fraction = fraction
        self.updatedAt = updatedAt.map(Timestamp.format)
    }

    /// Video and audio position.
    public static func media(positionMs: Int, durationMs: Int, at date: Date? = nil) -> ProgressUpdate {
        ProgressUpdate(positionMs: positionMs, durationMs: durationMs, updatedAt: date)
    }

    /// Book and comic reader position.
    public static func reader(locator: String, fraction: Double, at date: Date? = nil) -> ProgressUpdate {
        ProgressUpdate(locator: locator, fraction: fraction, updatedAt: date)
    }
}

/// One result of OpenSubtitles search (`GET /api/subtitles/{fileId}/search`).
public struct SubtitleSearchResult: Decodable, Hashable, Identifiable, Sendable {
    public var subtitleId: Int
    public var lang: String
    public var release: String
    public var downloads: Int
    public var hashMatch: Bool

    public var id: Int { subtitleId }

    enum CodingKeys: String, CodingKey { case subtitleId, lang, release, downloads, hashMatch }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        subtitleId = try c.decode(Int.self, forKey: .subtitleId)
        lang = c.value(.lang, default: "")
        release = c.value(.release, default: "")
        downloads = c.value(.downloads, default: 0)
        hashMatch = c.value(.hashMatch, default: false)
    }
}

struct SubtitleSearchResponse: Decodable, Sendable {
    var results: [SubtitleSearchResult]

    enum CodingKeys: String, CodingKey { case results }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        results = c.value(.results, default: [])
    }
}
