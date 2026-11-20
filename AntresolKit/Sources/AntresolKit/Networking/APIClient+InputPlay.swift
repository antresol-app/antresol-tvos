import Foundation

// The core's input player: a stream an addon registered (`/api/play/input/{id}`). It plays like a
// library file, but the server may need a while to get it ready.

/// `GET /api/play/input/{id}`: what the player shows and where it starts.
public struct InputInfo: Decodable, Hashable, Sendable {
    public var id: String
    public var name: String
    /// The library item whose position this stream saves; 0 when none.
    public var itemId: Int
    /// The server can take long to get it ready.
    public var slow: Bool
    /// Seconds; the saved position of the library item, 0 when none or finished.
    public var startSec: Double

    public init(id: String, name: String = "", itemId: Int = 0, slow: Bool = false, startSec: Double = 0) {
        self.id = id
        self.name = name
        self.itemId = itemId
        self.slow = slow
        self.startSec = startSec
    }

    enum CodingKeys: String, CodingKey { case id, name, itemId, slow, startSec }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = c.value(.name, default: "")
        itemId = c.value(.itemId, default: 0)
        slow = c.value(.slow, default: false)
        startSec = max(0, c.value(.startSec, default: 0))
    }
}

/// The answer of `POST /api/play/input/{id}`: still getting ready (`202`), or how to play.
public enum InputPlayAnswer: Sendable {
    case pending
    case ready(PlayResponse)
}

extension APIClient {
    /// How long `startInputPlay` waits for the server to get a stream ready.
    public static let inputReadyBudget: Double = 90
    /// Seconds between two asks while it is not ready.
    public static let inputPollInterval: Double = 1.5

    /// `GET /api/play/input/{id}`.
    public func inputInfo(id: String) async throws -> InputInfo {
        try await send(.get, try inputPath(id))
    }

    /// `POST /api/play/input/{id}` with the `/api/play` body: `202 {pending:true}` while the server
    /// probes the stream, else the `/api/play` answer.
    public func playInput(id: String, _ request: PlayRequest) async throws -> InputPlayAnswer {
        struct Pending: Decodable {
            var pending: Bool?
            enum CodingKeys: String, CodingKey { case pending }
            init(from decoder: Decoder) throws {
                pending = try? decoder.container(keyedBy: CodingKeys.self).decodeIfPresent(Bool.self, forKey: .pending)
            }
        }
        let path = try inputPath(id)
        var urlRequest = try makeRequest(.post, path, body: try APIClient.encoder.encode(request))
        // The server answers 202 itself after 25 s; a slow proxy should not cut it short.
        urlRequest.timeoutInterval = 60
        let (data, response) = try await perform(urlRequest)
        if response.statusCode == 202 || (try? APIClient.decoder.decode(Pending.self, from: data))?.pending == true {
            return .pending
        }
        do {
            return .ready(try APIClient.decoder.decode(PlayResponse.self, from: data))
        } catch {
            throw APIError.decoding("POST \(path): \(error)")
        }
    }

    /// Asks `playInput` again every `inputPollInterval` seconds while the server says `pending`, for
    /// up to `inputReadyBudget` seconds in all, then throws a gateway timeout. Cancelling the task
    /// stops the asking.
    public func startInputPlay(
        id: String, _ request: PlayRequest,
        sleep: @escaping @Sendable (Double) async throws -> Void = { seconds in
            try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
        }
    ) async throws -> PlayResponse {
        var waited = 0.0
        while true {
            if case .ready(let response) = try await playInput(id: id, request) {
                return response
            }
            guard waited + Self.inputPollInterval <= Self.inputReadyBudget else {
                throw APIError.server(status: 504, message: nil, code: "input-not-ready", retryAfter: nil)
            }
            try await sleep(Self.inputPollInterval)
            waited += Self.inputPollInterval
        }
    }

    /// `PUT /api/play/input/{id}/progress` → 204. `keepalive` marks a write that must not be
    /// held back: the end, a pause, the player closing.
    public func updateInputProgress(id: String, positionMs: Int, durationMs: Int, keepalive: Bool) async throws {
        struct Body: Encodable {
            var positionMs: Int
            var durationMs: Int
            var keepalive: Bool
        }
        try await sendWithoutResponse(
            .put, try inputPath(id) + "/progress",
            json: Body(positionMs: positionMs, durationMs: durationMs, keepalive: keepalive)
        )
    }

    /// `/api/play/input/{id}`: an input id is a plain word.
    func inputPath(_ id: String) throws -> String {
        guard AddonID.isValid(id) else { throw APIError.invalidURL("input \(id)") }
        return "/api/play/input/\(id)"
    }
}
