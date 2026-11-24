import Foundation

// Video playback sessions and subtitles (§5).
extension APIClient {
    /// `POST /api/play/{fileId}`: asks how to play a file. Always pass caps.
    public func play(fileId: Int, _ request: PlayRequest) async throws -> PlayResponse {
        try await send(.post, "/api/play/\(fileId)", json: request)
    }

    /// `PUT /api/hls/{session}`: keepalive, every 20 s. `404` means the session is gone.
    @discardableResult
    public func keepAlive(hlsSession: String) async throws -> HLSStatus {
        try await send(.put, "/api/hls/\(hlsSession)")
    }

    /// `DELETE /api/hls/{session}`: stops a transcoding session.
    public func stop(hlsSession: String) async throws {
        try await sendWithoutResponse(.delete, "/api/hls/\(hlsSession)")
    }

    /// Downloads a WebVTT subtitle (`SubtitleTrack.url`) with the Bearer header,
    /// retrying while the server is still extracting it (`Retry-After`).
    public func subtitleText(path: String, maxAttempts: Int = 5) async throws -> String {
        var attempt = 0
        while true {
            attempt += 1
            do {
                let data = try await data(path: path)
                return String(decoding: data, as: UTF8.self)
            } catch let APIError.server(_, _, _, retryAfter?) where attempt < maxAttempts {
                try await Task.sleep(nanoseconds: UInt64(min(max(retryAfter, 0.5), 10) * 1_000_000_000))
            }
        }
    }

    /// Downloads and parses a WebVTT subtitle.
    public func subtitleCues(path: String) async throws -> [SubtitleCue] {
        WebVTT.parse(try await subtitleText(path: path))
    }
}
