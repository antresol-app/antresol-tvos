import Foundation

/// The answer of `POST /api/trailers/{key}/play`: the cached MP4, signed with the media key
/// (`mk`) like `/api/play`'s URLs, so a player loads it without headers.
public struct TrailerPlayback: Decodable, Hashable, Sendable {
    /// A server path (`/api/trailers/<key>.mp4?mk=…`), or an absolute URL.
    public var url: String
    public var durationMs: Int

    public init(url: String, durationMs: Int = 0) {
        self.url = url
        self.durationMs = durationMs
    }

    enum CodingKeys: String, CodingKey { case url, durationMs }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        url = try c.decode(String.self, forKey: .url)
        durationMs = c.value(.durationMs, default: 0)
    }
}
