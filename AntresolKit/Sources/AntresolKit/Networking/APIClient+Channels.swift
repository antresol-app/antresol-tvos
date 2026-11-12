import Foundation

// Live channels («ТВ», §12).
extension APIClient {
    /// `GET /api/channels`: the channels this profile sees, with what is on now and next.
    public func channels() async throws -> ChannelList {
        try await send(.get, "/api/channels")
    }

    /// `GET /api/channels/{id}/guide?hours=`: the programmes from the one on air on.
    public func channelGuide(id: Int, hours: Int = 6) async throws -> ChannelGuide {
        try await send(.get, "/api/channels/\(id)/guide", query: [URLQueryItem(name: "hours", value: String(hours))])
    }

    /// `GET /api/channels/epg?from=&hours=`: every channel with the programmes that overlap
    /// `[from, from + hours)`. The server clamps `from` to the schedule it keeps.
    public func channelEPG(from: Date? = nil, hours: Int = 6) async throws -> ChannelEPGWindow {
        var query = [URLQueryItem(name: "hours", value: String(min(max(hours, 1), 24)))]
        if let from { query.insert(URLQueryItem(name: "from", value: Timestamp.format(from)), at: 0) }
        return try await send(.get, "/api/channels/epg", query: query)
    }

    /// `PUT` / `DELETE /api/channels/{id}/favorite`: one of the profile's favourites or not.
    public func setChannelFavorite(id: Int, _ favorite: Bool) async throws {
        try await sendWithoutResponse(favorite ? .put : .delete, "/api/channels/\(id)/favorite")
    }

    /// `PUT /api/channels/last`: the channel just tuned in, the profile's «last channel».
    /// It is not media progress: the server keeps one id per profile and nothing else.
    /// `POST /api/channels/opened`: «ТВ» opened (the server refreshes the external sources
    /// marked «при открытии» whose last refresh is over an hour old). Writes nothing about
    /// the profile.
    public func channelsOpened() async throws {
        try await sendWithoutResponse(.post, "/api/channels/opened")
    }

    public func setLastChannel(id: Int) async throws {
        try await sendWithoutResponse(.put, "/api/channels/last", json: LastChannelBody(channelId: id))
    }

    /// Starts a channel's live stream and returns the playlist URL for the player once the
    /// server serves it. The first request starts the channel's encoder: the server may
    /// hold it for a while or answer `503` with a short `Retry-After`, which is retried
    /// (`onStarting` is called before each wait). Other errors (busy server, screen time,
    /// a gone channel) are thrown with the server's message.
    public func startLiveChannel(
        id: Int, mediaKey: String?, maxAttempts: Int = 15,
        onStarting: @Sendable () async -> Void = {}
    ) async throws -> URL {
        try await startLiveStream(id: id, mediaKey: mediaKey, maxAttempts: maxAttempts, onStarting: onStarting).url
    }

    /// `startLiveChannel`, with the renditions of the master playlist it fetched: the player
    /// tells AVFoundation's options apart by them (`LiveRenditions`).
    public func startLiveStream(
        id: Int, mediaKey: String?, maxAttempts: Int = 15,
        onStarting: @Sendable () async -> Void = {}
    ) async throws -> LiveStream {
        guard let url = urls.liveChannel(id: id, mediaKey: mediaKey) else {
            throw APIError.invalidURL("/api/channels/live/\(id)/index.m3u8")
        }
        var attempt = 0
        while true {
            attempt += 1
            do {
                var request = try makeRequest(.get, "/api/channels/live/\(id)/index.m3u8", query: ServerURLs.mediaKeyQuery(mediaKey))
                request.setValue("application/vnd.apple.mpegurl", forHTTPHeaderField: "Accept")
                let (data, _) = try await perform(request)
                return LiveStream(url: url, renditions: LiveRenditions(master: data))
            } catch let error as APIError {
                guard attempt < maxAttempts, let delay = LiveChannelStart.retryDelay(after: error) else { throw error }
                await onStarting()
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
    }
}

/// A channel's live stream as the player gets it: the playlist URL and the master's renditions.
public struct LiveStream: Sendable, Equatable {
    public let url: URL
    public let renditions: LiveRenditions

    public init(url: URL, renditions: LiveRenditions = LiveRenditions()) {
        self.url = url
        self.renditions = renditions
    }
}

private struct LastChannelBody: Encodable {
    let channelId: Int
}

/// When a live channel's playlist request is worth repeating.
public enum LiveChannelStart {
    /// Longest `Retry-After` still treated as "the channel is starting"; the server asks
    /// for 30 s when too many channels are on, which is shown instead.
    public static let startingRetryLimit: Double = 10

    /// The wait before the next attempt, or nil when the error should be shown.
    public static func retryDelay(after error: APIError) -> Double? {
        guard case .server(503, _, _, let retryAfter?) = error, retryAfter <= startingRetryLimit else { return nil }
        return min(max(retryAfter, 0.5), startingRetryLimit)
    }
}
