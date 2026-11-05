import Foundation
import XCTest
@testable import AntresolKit
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class ClientTests: XCTestCase {
    let base = URL(string: "http://tv.test:8420")!

    func testHeadersAndBody() async throws {
        let transport = MockTransport { _ in .json(#"{"token":"t0k","user":{"id":1,"name":"Admin","avatar":"grad-1"}}"#) }
        let client = APIClient(baseURL: base, language: "ru-RU", transport: transport)
        let device = DeviceInfo(id: "device-1234", name: "Living Room", model: "AppleTV14,1", version: "1.0")
        try await client.signIn(userId: 1, password: "", device: device)
        XCTAssertEqual(client.token, "t0k")

        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.pathAndQuery, "/api/auth/token")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept-Language"), "ru")
        XCTAssertNil(request.value(forHTTPHeaderField: "Origin"))
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        let body = try XCTUnwrap(request.bodyJSON)
        XCTAssertEqual(body["userId"] as? Int, 1)
        XCTAssertNil(body["password"], "an empty password is omitted")
        XCTAssertEqual((body["device"] as? [String: Any])?["id"] as? String, "device-1234")

        _ = try? await client.me()
        XCTAssertEqual(transport.requests.last?.value(forHTTPHeaderField: "Authorization"), "Bearer t0k")
    }

    func testBodylessMutationHasNoContentType() async throws {
        let transport = MockTransport { _ in .noContent }
        let client = APIClient(baseURL: base, token: "t", transport: transport)
        try await client.setInWatchlist(itemId: 19, true)
        try await client.setInWatchlist(itemId: 19, false)
        XCTAssertEqual(transport.requests.map(\.httpMethod), ["POST", "DELETE"])
        XCTAssertNil(transport.requests[0].value(forHTTPHeaderField: "Content-Type"))
        XCTAssertNil(transport.requests[0].httpBody)
    }

    func testErrorMapping() async {
        let transport = MockTransport { request in
            switch request.url?.path {
            case "/api/me": return .json(#"{"error":"Sign in required"}"#, status: 401)
            case "/api/play/1": return .json(#"{"error":"This profile is already watching on another device"}"#, status: 429)
            case "/api/subs/1/3.vtt": return .json(#"{"error":"Video is still being prepared"}"#, status: 503, headers: ["Retry-After": "2"])
            default: return .json("404 page not found", status: 404)
            }
        }
        let client = APIClient(baseURL: base, token: "t", transport: transport)

        do {
            _ = try await client.me()
            XCTFail("expected 401")
        } catch {
            XCTAssertEqual(error as? APIError, .unauthorized(message: "Sign in required"))
        }

        do {
            _ = try await client.play(fileId: 1, PlayRequest(caps: .appleTV()))
            XCTFail("expected 429")
        } catch let error as APIError {
            XCTAssertTrue(error.isTooManySessions)
            XCTAssertEqual(error.serverMessage, "This profile is already watching on another device")
        } catch {
            XCTFail("\(error)")
        }

        do {
            _ = try await client.data(path: "/api/subs/1/3.vtt")
            XCTFail("expected 503")
        } catch {
            XCTAssertEqual(error as? APIError, .server(status: 503, message: "Video is still being prepared", code: nil, retryAfter: 2))
        }

        do {
            _ = try await client.item(id: 999)
            XCTFail("expected 404")
        } catch let error as APIError {
            XCTAssertTrue(error.isNotFound)
            XCTAssertEqual(error.serverMessage, "404 page not found")
        } catch {
            XCTFail("\(error)")
        }
    }

    func testLyricsNotFoundIsNil() async throws {
        let transport = MockTransport { _ in .json(#"{"error":"No lyrics"}"#, status: 404) }
        let client = APIClient(baseURL: base, token: "t", transport: transport)
        let lyrics = try await client.lyrics(trackId: 16)
        XCTAssertNil(lyrics)
    }

    func testQueryParameters() async throws {
        let transport = MockTransport { request in
            if request.url?.path == "/api/music/shuffle" { return .json(#"{"tracks":[]}"#) }
            return .json(#"{"items":[],"total":0}"#)
        }
        let client = APIClient(baseURL: base, token: "t", transport: transport)
        _ = try await client.items(kind: .movie, sort: .title, offset: 120)
        _ = try await client.albums(sort: .year, genre: "Rock", artistId: 13, starred: true)
        _ = try await client.books(kind: .comic, sort: .author, limit: nil)
        _ = try await client.shuffle(.genre("Hip Hop"))
        XCTAssertEqual(transport.requests.map(\.pathAndQuery), [
            "/api/items?kind=movie&sort=title&limit=120&offset=120",
            "/api/music/albums?sort=year&genre=Rock&artist=13&starred=1&limit=120",
            "/api/books?kind=comic&sort=author",
            "/api/music/shuffle?source=genre&genre=Hip%20Hop",
        ])
    }

    func testMediaKeyStoreCachesUntilNearExpiry() async throws {
        let clock = Locked(Date(timeIntervalSince1970: 1_800_000_000))
        let transport = MockTransport { _ in
            let expiry = Timestamp.format(clock.current.addingTimeInterval(12 * 3600))
            return .json(#"{"key":"k-\#(replyCounter.next())","expiresAt":"\#(expiry)"}"#)
        }
        let client = APIClient(baseURL: base, token: "t", transport: transport)
        let store = MediaKeyStore(client: client, now: { clock.current })
        let first = try await store.key()
        let second = try await store.key()
        XCTAssertEqual(first, second)
        XCTAssertEqual(transport.requests.count, 1)

        clock.withLock { $0.addTimeInterval(11.5 * 3600) }
        let third = try await store.key()
        XCTAssertNotEqual(third, first)
        XCTAssertEqual(transport.requests.count, 2)
        XCTAssertEqual(transport.requests[0].httpMethod, "POST")
    }

    func testProgressReporter() async throws {
        let transport = MockTransport { _ in .noContent }
        let client = APIClient(baseURL: base, token: "t", transport: transport)
        let reporter = ProgressReporter(client: client, itemId: 19)

        await reporter.reportIfMoved()
        XCTAssertTrue(transport.requests.isEmpty, "nothing recorded yet")

        await reporter.update(positionMs: 10_000, durationMs: 60_046)
        await reporter.reportIfMoved()
        XCTAssertEqual(transport.requests.count, 1)

        await reporter.update(positionMs: 10_300, durationMs: 60_046)
        await reporter.reportIfMoved()
        XCTAssertEqual(transport.requests.count, 1, "moved less than 0.5 s")

        await reporter.flush()
        XCTAssertEqual(transport.requests.count, 2, "flush writes any change")
        await reporter.flush()
        XCTAssertEqual(transport.requests.count, 2, "no change, no write")

        let last = try XCTUnwrap(transport.requests.last)
        XCTAssertEqual(last.httpMethod, "PUT")
        XCTAssertEqual(last.pathAndQuery, "/api/progress/19")
        XCTAssertEqual(last.bodyJSON?["positionMs"] as? Int, 10_300)
        XCTAssertEqual(last.bodyJSON?["durationMs"] as? Int, 60_046)
        XCTAssertNil(last.bodyJSON?["locator"])
    }

    func testVideoSessionReplacesAndStops() async throws {
        let sessions = Locked(0)
        let transport = MockTransport { request in
            switch (request.httpMethod ?? "", request.url?.path ?? "") {
            case ("POST", "/api/auth/media-key"):
                return .json(#"{"key":"mk1","expiresAt":"2099-01-01T00:00:00Z"}"#)
            case ("POST", "/api/play/12"):
                let n = sessions.withLock { value -> Int in value += 1; return value }
                let start = (request.bodyJSON?["startSec"] as? Double) ?? 0
                return .json(#"{"mode":"remux","url":"/api/hls/s\#(n)/index.m3u8","reason":"","startSec":\#(start),"durationMs":60046,"audioIndex":1,"audio":[],"subtitles":[],"quality":{"selected":"auto","applied":"original","remote":false},"hlsComplete":true}"#)
            default:
                return .noContent
            }
        }
        let client = APIClient(baseURL: base, token: "t", transport: transport)
        let session = VideoPlaybackSession(client: client, mediaKeys: MediaKeyStore(client: client), fileId: 12, keepAliveInterval: 3600)

        let first = try await session.start(at: 0)
        XCTAssertEqual(first.url.absoluteString, "http://tv.test:8420/api/hls/s1/index.m3u8?mk=mk1")
        let firstPlay = try XCTUnwrap(transport.requests.first { $0.url?.path == "/api/play/12" })
        let caps = try XCTUnwrap(firstPlay.bodyJSON?["caps"] as? [String: Any])
        XCTAssertEqual(caps["hevcNeedsHvc1"] as? Bool, true)
        XCTAssertNil(firstPlay.bodyJSON?["replaceSession"])

        // A complete playlist is requested from the start; the player seeks to 30 s itself.
        let second = try await session.start(at: 30, options: PlaybackOptions(audioIndex: 2))
        XCTAssertEqual(second.hlsSessionID, "s2")
        XCTAssertEqual(second.timelineOffset, 0)
        XCTAssertEqual(second.initialPlayerSeek, 30)
        let secondPlay = try XCTUnwrap(transport.requests.last { $0.url?.path == "/api/play/12" })
        XCTAssertEqual(secondPlay.bodyJSON?["replaceSession"] as? String, "s1")
        XCTAssertEqual(secondPlay.bodyJSON?["audioIndex"] as? Int, 2)
        XCTAssertEqual(secondPlay.bodyJSON?["startSec"] as? Double, 0)

        await session.stop()
        let last = try XCTUnwrap(transport.requests.last)
        XCTAssertEqual(last.httpMethod, "DELETE")
        XCTAssertEqual(last.url?.path, "/api/hls/s2")
        let current = await session.current
        XCTAssertNil(current)
    }

    func testVideoSessionStartsGrowingPlaylistAtPosition() async throws {
        let sessions = Locked(0)
        let transport = MockTransport { request in
            switch (request.httpMethod ?? "", request.url?.path ?? "") {
            case ("POST", "/api/auth/media-key"):
                return .json(#"{"key":"mk1","expiresAt":"2099-01-01T00:00:00Z"}"#)
            case ("POST", "/api/play/7"):
                let n = sessions.withLock { value -> Int in value += 1; return value }
                let start = (request.bodyJSON?["startSec"] as? Double) ?? 0
                return .json(#"{"mode":"transcode","url":"/api/hls/e\#(n)/index.m3u8","startSec":\#(max(0, start - 2)),"durationMs":60000}"#)
            default:
                return .noContent
            }
        }
        let client = APIClient(baseURL: base, token: "t", transport: transport)
        let session = VideoPlaybackSession(client: client, mediaKeys: MediaKeyStore(client: client), fileId: 7, keepAliveInterval: 3600)

        let source = try await session.start(at: 40)
        let plays = transport.requests.filter { $0.url?.path == "/api/play/7" }
        XCTAssertEqual(plays.count, 2)
        XCTAssertEqual(plays[1].bodyJSON?["startSec"] as? Double, 40)
        XCTAssertEqual(plays[1].bodyJSON?["replaceSession"] as? String, "e1")
        XCTAssertEqual(source.hlsSessionID, "e2")
        XCTAssertEqual(source.timelineOffset, 38)
        XCTAssertEqual(source.initialPlayerSeek, 2)
        await session.stop()
    }

    func testKeepAliveExpiry() async throws {
        let expired = expectation(description: "expired")
        let transport = MockTransport { request in
            switch (request.httpMethod ?? "", request.url?.path ?? "") {
            case ("POST", "/api/auth/media-key"):
                return .json(#"{"key":"mk","expiresAt":"2099-01-01T00:00:00Z"}"#)
            case ("POST", "/api/play/5"):
                return .json(#"{"mode":"transcode","url":"/api/hls/gone/index.m3u8","startSec":0,"durationMs":1000}"#)
            case ("PUT", "/api/hls/gone"):
                return .json(#"{"error":"Session not found"}"#, status: 404)
            default:
                return .noContent
            }
        }
        let client = APIClient(baseURL: base, token: "t", transport: transport)
        let session = VideoPlaybackSession(client: client, mediaKeys: MediaKeyStore(client: client), fileId: 5, keepAliveInterval: 0.05)
        await session.onEnded { reason in
            XCTAssertEqual(reason, .expired)
            expired.fulfill()
        }
        try await session.start(at: 0)
        await fulfillment(of: [expired], timeout: 5)
        let current = await session.current
        XCTAssertNil(current)
    }

    func testKeepAliveUnauthorizedEndsSession() async throws {
        let ended = expectation(description: "unauthorized")
        let transport = MockTransport { request in
            switch (request.httpMethod ?? "", request.url?.path ?? "") {
            case ("POST", "/api/auth/media-key"):
                return .json(#"{"key":"mk","expiresAt":"2099-01-01T00:00:00Z"}"#)
            case ("POST", "/api/play/5"):
                return .json(#"{"mode":"transcode","url":"/api/hls/s/index.m3u8","startSec":0,"durationMs":1000}"#)
            case ("PUT", "/api/hls/s"):
                return .json(#"{"error":"Sign in required"}"#, status: 401)
            default:
                return .noContent
            }
        }
        let client = APIClient(baseURL: base, token: "t", transport: transport)
        let session = VideoPlaybackSession(client: client, mediaKeys: MediaKeyStore(client: client), fileId: 5, keepAliveInterval: 0.05)
        await session.onEnded { reason in
            XCTAssertEqual(reason, .unauthorized)
            ended.fulfill()
        }
        try await session.start(at: 0)
        await fulfillment(of: [ended], timeout: 5)
        try await Task.sleep(nanoseconds: 200_000_000)
        let pings = transport.requests.filter { $0.httpMethod == "PUT" }.count
        XCTAssertEqual(pings, 1, "keepalive stops after a 401")
    }

    func testStopDuringStartDeletesTheNewSession() async throws {
        let gate = Locked<CheckedContinuation<Void, Never>?>(nil)
        let playStarted = expectation(description: "play requested")
        let transport = MockTransport { request in
            switch (request.httpMethod ?? "", request.url?.path ?? "") {
            case ("POST", "/api/auth/media-key"):
                return .json(#"{"key":"mk","expiresAt":"2099-01-01T00:00:00Z"}"#)
            case ("POST", "/api/play/9"):
                return .json(#"{"mode":"remux","url":"/api/hls/late/index.m3u8","startSec":0,"durationMs":1000,"hlsComplete":true}"#)
            default:
                return .noContent
            }
        }
        transport.beforeReply = { request in
            guard request.url?.path == "/api/play/9" else { return }
            playStarted.fulfill()
            await withCheckedContinuation { continuation in gate.withLock { $0 = continuation } }
        }
        let client = APIClient(baseURL: base, token: "t", transport: transport)
        let session = VideoPlaybackSession(client: client, mediaKeys: MediaKeyStore(client: client), fileId: 9, keepAliveInterval: 3600)
        let start = Task { try await session.start(at: 0) }
        await fulfillment(of: [playStarted], timeout: 5)
        await session.stop()
        gate.withLock { $0?.resume() }
        do {
            _ = try await start.value
            XCTFail("start should give up after stop")
        } catch is CancellationError {}
        let deleted = transport.requests.contains { $0.httpMethod == "DELETE" && $0.url?.path == "/api/hls/late" }
        XCTAssertTrue(deleted)
        let current = await session.current
        XCTAssertNil(current)
    }
}

/// Monotonic counter for mock replies.
let replyCounter = Counter()

final class Counter: @unchecked Sendable {
    private let value = Locked(0)

    func next() -> Int {
        value.withLock { current -> Int in current += 1; return current }
    }
}
