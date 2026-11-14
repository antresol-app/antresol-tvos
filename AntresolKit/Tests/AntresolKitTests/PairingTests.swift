import Foundation
import XCTest
@testable import AntresolKit

final class PairingTests: XCTestCase {
    let base = URL(string: "http://tv.test:8420")!
    let device = DeviceInfo(id: "a1b2c3d4-0000", name: "Apple TV", model: "AppleTV14,1", version: "1.1.0")
    let userJSON = #"{"id":3,"name":"Аня","avatar":"grad-2","hasPassword":true,"isAdmin":false,"isKid":false,"remote":false}"#

    // MARK: codes

    func testCodeDisplayAndNormalize() {
        XCTAssertEqual(PairingCode.display("ABC234"), "ABC 234")
        XCTAssertEqual(PairingCode.normalize("abc-234"), "ABC234")
        XCTAssertEqual(PairingCode.normalize(" ab c 2 34 "), "ABC234")
        XCTAssertNil(PairingCode.normalize("ABC23"), "too short")
        XCTAssertNil(PairingCode.normalize("ABC10O"), "0, 1 and O are not in the alphabet")
    }

    // MARK: client

    func testStartSendsTheDeviceAndShiftsTheExpiryOntoTheLocalClock() async throws {
        let transport = MockTransport { _ in
            .json(#"""
            {"code":"ABC234","secret":"s3cr3t","expiresAt":"2026-11-14T12:05:00Z","interval":2,
             "url":"http://192.168.1.10:8420/pair?code=ABC234&sid=0123456789abcdef0123456789abcdef","serverId":"0123456789abcdef0123456789abcdef"}
            """#, headers: ["Date": "Sat, 14 Nov 2026 12:00:00 GMT"])
        }
        let client = APIClient(baseURL: base, transport: transport)
        // this device's clock is 10 s ahead of the server's
        let now = try XCTUnwrap(Timestamp.parse("2026-11-14T12:00:10Z"))
        let ticket = try await client.pairStart(device: device, now: now)
        XCTAssertEqual(ticket.code, "ABC234")
        XCTAssertEqual(ticket.displayCode, "ABC 234")
        XCTAssertEqual(ticket.secret, "s3cr3t")
        XCTAssertEqual(ticket.interval, 2)
        XCTAssertEqual(ticket.expiresAt, Timestamp.parse("2026-11-14T12:05:10Z"), "5 minutes from now on the local clock")
        XCTAssertEqual(ticket.pairPage, "192.168.1.10:8420/pair")

        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.pathAndQuery, "/api/auth/pair/start")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        let sent = try XCTUnwrap(request.bodyJSON?["device"] as? [String: Any])
        XCTAssertEqual(sent["id"] as? String, "a1b2c3d4-0000")
        XCTAssertEqual(sent["name"] as? String, "Apple TV")
    }

    func testPollAnswers() async throws {
        let replies = Locked<[MockTransport.Reply]>([
            .json(#"{"status":"pending","expiresAt":"2026-11-14T12:05:00Z","interval":3}"#),
            .json(#"{"status":"approved","token":"tok","user":\#(userJSON)}"#),
            .json(#"{"status":"denied","error":"Вход отклонён"}"#, status: 410),
            .json(#"{"status":"expired","error":"Код устарел"}"#, status: 410),
            .json("", status: 410),
            .json(#"{"error":"Слишком много попыток"}"#, status: 429, headers: ["Retry-After": "30"]),
        ])
        let transport = MockTransport { _ in replies.withLock { $0.removeFirst() } }
        let client = APIClient(baseURL: base, transport: transport)

        guard case .pending(let expiry, let interval) = try await client.pairPoll(secret: "s") else { return XCTFail("pending") }
        XCTAssertEqual(expiry, Timestamp.parse("2026-11-14T12:05:00Z"))
        XCTAssertEqual(interval, 3)
        guard case .approved(let token, let user) = try await client.pairPoll(secret: "s") else { return XCTFail("approved") }
        XCTAssertEqual(token, "tok")
        XCTAssertEqual(user.id, 3)
        XCTAssertEqual(user.name, "Аня")
        let denied = try await client.pairPoll(secret: "s")
        XCTAssertEqual(denied, .denied)
        let expired = try await client.pairPoll(secret: "s")
        XCTAssertEqual(expired, .expired)
        let emptyGone = try await client.pairPoll(secret: "s")
        XCTAssertEqual(emptyGone, .expired, "a 410 without a body is an expired code")
        do {
            _ = try await client.pairPoll(secret: "s")
            XCTFail("429 throws")
        } catch let error as APIError {
            XCTAssertEqual(error.statusCode, 429)
            XCTAssertEqual(PairingSession.delay(after: error), 30)
        }
        XCTAssertEqual(transport.requests.first?.bodyJSON?["secret"] as? String, "s")
        XCTAssertFalse(transport.requests.first?.url?.absoluteString.contains("s3cr3t") ?? true)
    }

    // MARK: session

    func testPendingThenApproved() async throws {
        let api = FakePairingAPI(polls: [.pending(expiresAt: nil, interval: nil), .pending(expiresAt: nil, interval: nil),
                                         .approved(token: "tok", user: User(id: 3, name: "Аня", avatar: "grad-2"))])
        let (states, result) = try await run(api)
        XCTAssertEqual(result, .approved(token: "tok", user: User(id: 3, name: "Аня", avatar: "grad-2")))
        XCTAssertEqual(states.map(Self.kind), ["starting", "waiting", "approved"])
        XCTAssertEqual(api.starts, 1)
        XCTAssertEqual(api.pollCount, 3)
    }

    func testDeniedIsTerminal() async throws {
        let api = FakePairingAPI(polls: [.pending(expiresAt: nil, interval: nil), .denied])
        let (states, result) = try await run(api)
        XCTAssertEqual(result, .denied)
        XCTAssertEqual(states.map(Self.kind), ["starting", "waiting", "denied"])
        XCTAssertEqual(api.starts, 1, "no new code without the user asking")
    }

    func testExpiredStartsANewCode() async throws {
        let api = FakePairingAPI(polls: [.pending(expiresAt: nil, interval: nil), .expired, .approved(token: "t2", user: User(id: 1, name: "A", avatar: ""))])
        let (states, result) = try await run(api)
        guard case .approved(let token, _) = result else { return XCTFail("\(result)") }
        XCTAssertEqual(token, "t2")
        XCTAssertEqual(api.starts, 2)
        XCTAssertEqual(states.map(Self.kind), ["starting", "waiting", "waiting", "approved"])
        guard case .waiting(let second) = states[2] else { return XCTFail() }
        XCTAssertEqual(second.code, "CODE02", "the new code is shown")
    }

    func testRunningOutOfTimeStartsANewCodeEvenWhileTheServerSaysPending() async throws {
        let clock = FakeClock()
        let api = FakePairingAPI(polls: [.pending(expiresAt: nil, interval: nil), .pending(expiresAt: nil, interval: nil),
                                         .approved(token: "t", user: User(id: 1, name: "A", avatar: ""))],
                                 clock: clock, ttl: 3)
        let (_, result) = try await run(api, clock: clock)
        XCTAssertNotNil(result)
        XCTAssertEqual(api.starts, 2, "the first code lived 3 s: the second poll at 4 s found it gone")
    }

    func testFailuresRetryAndRateLimitsWait() async throws {
        let api = FakePairingAPI(polls: [.approved(token: "t", user: User(id: 1, name: "A", avatar: ""))])
        api.startErrors = [APIError.transport("offline"), APIError.server(status: 429, message: nil, code: nil, retryAfter: 12)]
        let clock = FakeClock()
        let (states, result) = try await run(api, clock: clock)
        XCTAssertNotNil(result)
        XCTAssertEqual(states.map(Self.kind), ["starting", "failed", "failed", "waiting", "approved"])
        XCTAssertEqual(clock.sleeps, [PairingSession.retryDelay, 12, 2])
    }

    func testPollErrorsKeepPolling() async throws {
        let api = FakePairingAPI(polls: [.approved(token: "t", user: User(id: 1, name: "A", avatar: ""))])
        api.pollErrors = [APIError.transport("lost"), APIError.server(status: 429, message: nil, code: nil, retryAfter: 30)]
        let clock = FakeClock()
        _ = try await run(api, clock: clock)
        XCTAssertEqual(api.starts, 1)
        XCTAssertEqual(clock.sleeps, [2, 2, 30], "interval, interval after the network error, Retry-After")
    }

    func testOldServerIsUnsupported() async throws {
        let api = FakePairingAPI(polls: [])
        api.startErrors = [APIError.server(status: 404, message: "not found", code: nil, retryAfter: nil)]
        let (states, result) = try await run(api)
        XCTAssertEqual(result, .unsupported)
        XCTAssertEqual(states.map(Self.kind), ["starting", "unsupported"])
    }

    func testCancellationStops() async throws {
        let api = FakePairingAPI(polls: Array(repeating: .pending(expiresAt: nil, interval: nil), count: 1000))
        let clock = FakeClock()
        let session = PairingSession(api: api, device: device, now: { clock.now }, sleep: { seconds in
            clock.advance(seconds)
            await Task.yield()
        })
        let task = Task { try await session.run { _ in } }
        while api.pollCount < 3 { await Task.yield() }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("a cancelled run throws")
        } catch is CancellationError {}
    }

    // MARK: helpers

    private func run(_ api: FakePairingAPI, clock: FakeClock = FakeClock()) async throws -> ([PairingState], PairingState) {
        let states = Locked<[PairingState]>([])
        let session = PairingSession(api: api, device: device, now: { clock.now }, sleep: { clock.advance($0) }, describe: { "\($0)" })
        let result = try await session.run { state in states.withLock { $0.append(state) } }
        return (states.current, result)
    }

    static func kind(_ state: PairingState) -> String {
        switch state {
        case .starting: return "starting"
        case .waiting: return "waiting"
        case .approved: return "approved"
        case .denied: return "denied"
        case .unsupported: return "unsupported"
        case .failed: return "failed"
        }
    }
}

final class FakeClock: @unchecked Sendable {
    private let state = Locked<(now: Date, sleeps: [Double])>((Date(timeIntervalSince1970: 1_800_000_000), []))
    var now: Date { state.current.now }
    var sleeps: [Double] { state.current.sleeps }
    func advance(_ seconds: Double) {
        state.withLock { $0.now.addTimeInterval(seconds); $0.sleeps.append(seconds) }
    }
}

final class FakePairingAPI: PairingAPI, @unchecked Sendable {
    private let state: Locked<(polls: [PairingPoll], starts: Int, pollCount: Int, startErrors: [Error], pollErrors: [Error])>
    let clock: FakeClock?
    let ttl: Double

    init(polls: [PairingPoll], clock: FakeClock? = nil, ttl: Double = 300) {
        state = Locked((polls, 0, 0, [], []))
        self.clock = clock
        self.ttl = ttl
    }

    var starts: Int { state.current.starts }
    var pollCount: Int { state.current.pollCount }
    var startErrors: [Error] {
        get { state.current.startErrors }
        set { state.withLock { $0.startErrors = newValue } }
    }
    var pollErrors: [Error] {
        get { state.current.pollErrors }
        set { state.withLock { $0.pollErrors = newValue } }
    }

    func pairStart(device: DeviceInfo, now: Date) async throws -> PairingTicket {
        let (error, n): (Error?, Int) = state.withLock { s in
            if !s.startErrors.isEmpty { return (s.startErrors.removeFirst(), s.starts) }
            s.starts += 1
            return (nil, s.starts)
        }
        if let error { throw error }
        return PairingTicket(code: String(format: "CODE%02d", n), secret: "secret-\(n)", url: "http://tv.test/pair?code=CODE0\(n)",
                             expiresAt: now.addingTimeInterval(ttl), interval: 2, serverId: "")
    }

    func pairPoll(secret: String, now: Date) async throws -> PairingPoll {
        let (error, answer): (Error?, PairingPoll?) = state.withLock { s in
            s.pollCount += 1
            if !s.pollErrors.isEmpty { return (s.pollErrors.removeFirst(), nil) }
            return (nil, s.polls.isEmpty ? .expired : s.polls.removeFirst())
        }
        if let error { throw error }
        return answer!
    }
}
