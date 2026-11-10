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

    /// Starts a channel's live stream and returns the playlist URL for the player once the
    /// server serves it. The first request starts the channel's encoder: the server may
    /// hold it for a while or answer `503` with a short `Retry-After`, which is retried
    /// (`onStarting` is called before each wait). Other errors (busy server, screen time,
    /// a gone channel) are thrown with the server's message.
    public func startLiveChannel(
        id: Int, mediaKey: String?, maxAttempts: Int = 15,
        onStarting: @Sendable () async -> Void = {}
    ) async throws -> URL {
        guard let url = urls.liveChannel(id: id, mediaKey: mediaKey) else {
            throw APIError.invalidURL("/api/channels/live/\(id)/index.m3u8")
        }
        var attempt = 0
        while true {
            attempt += 1
            do {
                var request = try makeRequest(.get, "/api/channels/live/\(id)/index.m3u8", query: ServerURLs.mediaKeyQuery(mediaKey))
                request.setValue("application/vnd.apple.mpegurl", forHTTPHeaderField: "Accept")
                _ = try await perform(request)
                return url
            } catch let error as APIError {
                guard attempt < maxAttempts, let delay = LiveChannelStart.retryDelay(after: error) else { throw error }
                await onStarting()
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
    }
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
