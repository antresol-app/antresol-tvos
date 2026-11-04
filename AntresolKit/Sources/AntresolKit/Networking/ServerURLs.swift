import Foundation

/// Builds absolute URLs for server resources.
///
/// - Images, subtitles and comic pages need the Bearer header (`APIClient.authorizationHeaders`).
/// - Stream, HLS, audio and track URLs accept a media key (`mk`) so players need no headers.
public struct ServerURLs: Hashable, Sendable {
    public let baseURL: URL

    public init(baseURL: URL) {
        self.baseURL = baseURL
    }

    /// `baseURL` + server-relative `path` (which may carry its own query) + extra query items.
    public func url(path: String, query: [URLQueryItem] = []) -> URL? {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else { return nil }
        let parts = path.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        var basePath = components.percentEncodedPath
        while basePath.hasSuffix("/") { basePath.removeLast() }
        // Server paths are already percent-encoded; escape anything else defensively.
        let relative = Self.escape(String(parts.first ?? ""), allowed: .urlPathAllowed)
        components.percentEncodedPath = basePath + (relative.hasPrefix("/") ? relative : "/" + relative)
        var query = query.map { item in
            Self.encode(item.name) + (item.value.map { "=" + Self.encode($0) } ?? "")
        }
        if parts.count > 1, !parts[1].isEmpty {
            query.insert(Self.escape(String(parts[1]), allowed: .urlQueryAllowed), at: 0)
        }
        components.percentEncodedQuery = query.isEmpty ? nil : query.joined(separator: "&")
        return components.url
    }

    /// Absolute URL of an image field (`poster`, `backdrop`, `logo`, `cover`). nil for `""`.
    public func image(_ path: String) -> URL? {
        let value = path.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty else { return nil }
        let lower = value.lowercased()
        if lower.hasPrefix("http:") || lower.hasPrefix("https:") || lower.hasPrefix("data:") {
            return URL(string: value)
        }
        if value.hasPrefix("/") {
            return url(path: value)
        }
        return url(path: "/api/images/" + Self.encode(value))
    }

    /// The URL to hand to the player for a `/api/play` response. HLS loaded with a media
    /// key yields a complete VOD playlist whose segment URIs are signed as well.
    public func playback(_ response: PlayResponse, mediaKey: String?) -> URL? {
        url(path: response.url, query: Self.mediaKeyQuery(mediaKey))
    }

    /// Progressive file at `/api/stream/{fileId}` (Range-capable).
    public func stream(fileId: Int, mediaKey: String?) -> URL? {
        url(path: "/api/stream/\(fileId)", query: Self.mediaKeyQuery(mediaKey))
    }

    /// `/api/download/{fileId}` (Bearer only).
    public func download(fileId: Int) -> URL? {
        url(path: "/api/download/\(fileId)")
    }

    /// Music track stream (§7.3).
    public func trackStream(
        trackId: Int, accept: [AudioCodec] = AudioCodec.apple, format: AudioTranscodeFormat? = nil,
        startSec: Double? = nil, mediaKey: String?
    ) -> URL? {
        url(path: "/api/tracks/\(trackId)/stream", query: Self.audioQuery(accept: accept, format: format, startSec: startSec, mediaKey: mediaKey))
    }

    /// Audiobook part stream (§8.3).
    public func audio(
        fileId: Int, accept: [AudioCodec] = AudioCodec.apple, format: AudioTranscodeFormat? = nil,
        startSec: Double? = nil, mediaKey: String?
    ) -> URL? {
        url(path: "/api/audio/\(fileId)", query: Self.audioQuery(accept: accept, format: format, startSec: startSec, mediaKey: mediaKey))
    }

    /// A WebVTT subtitle from `SubtitleTrack.url` (Bearer only).
    public func subtitle(_ path: String) -> URL? {
        url(path: path)
    }

    /// A comic page image; `index` is 0-based (Bearer only).
    public func comicPage(fileId: Int, index: Int) -> URL? {
        url(path: "/api/comics/\(fileId)/page/\(index)")
    }

    /// Server-sent events stream (Bearer only).
    public func events(language: String) -> URL? {
        url(path: "/api/events", query: [URLQueryItem(name: "lang", value: language)])
    }

    /// Strict query encoding: only RFC 3986 unreserved characters stay literal, so
    /// values such as "R&B" or "a+b" survive the server's form decoding.
    static func encode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value
    }

    static func escape(_ value: String, allowed: CharacterSet) -> String {
        value.addingPercentEncoding(withAllowedCharacters: allowed.union(CharacterSet(charactersIn: "%"))) ?? value
    }

    private static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    static func mediaKeyQuery(_ key: String?) -> [URLQueryItem] {
        guard let key, !key.isEmpty else { return [] }
        return [URLQueryItem(name: "mk", value: key)]
    }

    static func audioQuery(accept: [AudioCodec], format: AudioTranscodeFormat?, startSec: Double?, mediaKey: String?) -> [URLQueryItem] {
        var items: [URLQueryItem] = []
        if !accept.isEmpty {
            items.append(URLQueryItem(name: "accept", value: accept.map(\.rawValue).joined(separator: ",")))
        }
        if let format {
            items.append(URLQueryItem(name: "format", value: format.rawValue))
        }
        if let startSec, startSec > 0 {
            items.append(URLQueryItem(name: "t", value: Self.seconds(startSec)))
        }
        return items + mediaKeyQuery(mediaKey)
    }

    static func seconds(_ value: Double) -> String {
        let rounded = (value * 1000).rounded() / 1000
        return rounded == rounded.rounded() ? String(Int(rounded)) : String(rounded)
    }
}
