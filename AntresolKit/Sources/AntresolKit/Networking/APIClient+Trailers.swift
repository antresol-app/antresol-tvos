import Foundation

// Trailers played by the server (`Trailer.play`).
extension APIClient {
    /// How long `playTrailer` keeps retrying a busy server (`503` + `Retry-After`).
    public static let trailerBusyBudget: Double = 30

    /// `POST {trailer.play}`: asks the server to have the trailer ready and returns its
    /// URL. The first fetch of a trailer can take up to a minute, so the request waits
    /// longer than others. A busy server (`503`) is asked again after its `Retry-After`,
    /// for up to `trailerBusyBudget` seconds in all; `502` (the fetch failed) and `404`
    /// (an unknown trailer) are thrown at once, as is the last `503`.
    public func playTrailer(
        _ trailer: Trailer,
        sleep: @escaping @Sendable (Double) async throws -> Void = { seconds in
            try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
        }
    ) async throws -> TrailerPlayback {
        guard let path = trailer.play else { throw APIError.invalidURL("trailer without play") }
        var waited = 0.0
        while true {
            var request = try makeRequest(.post, path)
            request.timeoutInterval = 90
            do {
                let (data, _) = try await perform(request)
                do {
                    return try APIClient.decoder.decode(TrailerPlayback.self, from: data)
                } catch {
                    throw APIError.decoding("POST \(path): \(error)")
                }
            } catch let error as APIError where error.statusCode == 503 {
                let delay = Self.busyDelay(error)
                guard waited + delay <= Self.trailerBusyBudget else { throw error }
                try await sleep(delay)
                waited += delay
            }
        }
    }

    /// The wait before asking a busy server again: its `Retry-After`, 1 to 10 s (2 s when it
    /// sent none).
    static func busyDelay(_ error: APIError) -> Double {
        guard case .server(_, _, _, let retryAfter?) = error else { return 2 }
        return min(max(retryAfter, 1), 10)
    }
}

extension ServerURLs {
    /// The player URL of a `playTrailer` answer: a server path resolved against the server,
    /// or the server's absolute http(s) URL as is.
    public func trailer(_ playback: TrailerPlayback) -> URL? {
        let value = playback.url.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty else { return nil }
        let lower = value.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") {
            return URL(string: value)
        }
        return value.hasPrefix("/") ? url(path: value) : nil
    }
}
