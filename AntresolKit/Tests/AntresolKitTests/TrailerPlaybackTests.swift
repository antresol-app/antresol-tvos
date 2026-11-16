import Foundation
import XCTest
@testable import AntresolKit
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Trailers the server plays itself: `play` on the list, `POST play`, its busy retries.
final class TrailerPlaybackTests: XCTestCase {
    private let base = URL(string: "http://tv.test:8420")!

    func testPlayFieldDecodes() throws {
        let json = #"""
        {"trailers":[
          {"key":"k1","name":"A","play":"/api/trailers/k1/play"},
          {"key":"k2","name":"B"},
          {"key":"k3","name":"C","play":"https://elsewhere.test/x"},
          {"key":"k4","name":"D","play":"/api/trailers/../play/1"},
          {"key":"k5","name":"E","play":""}
        ]}
        """#
        let trailers = try JSONDecoder().decode(TrailerList.self, from: Data(json.utf8)).trailers
        XCTAssertEqual(trailers.map(\.key), ["k1", "k2", "k3", "k4", "k5"])
        XCTAssertEqual(trailers.map(\.play), ["/api/trailers/k1/play", nil, nil, nil, nil], "only a server path under /api/trailers/ is kept")
        XCTAssertEqual(trailers.map(\.playsInApp), [true, false, false, false, false])
    }

    func testPlaybackDecodes() throws {
        let playback = try JSONDecoder().decode(TrailerPlayback.self, from: Data(#"{"url":"/api/trailers/k1.mp4?mk=abc","durationMs":120500}"#.utf8))
        XCTAssertEqual(playback, TrailerPlayback(url: "/api/trailers/k1.mp4?mk=abc", durationMs: 120500))
        let bare = try JSONDecoder().decode(TrailerPlayback.self, from: Data(#"{"url":"/api/trailers/k1.mp4"}"#.utf8))
        XCTAssertEqual(bare.durationMs, 0)
        XCTAssertThrowsError(try JSONDecoder().decode(TrailerPlayback.self, from: Data("{}".utf8)), "a url is required")
    }

    func testTrailerURL() {
        let urls = ServerURLs(baseURL: base)
        XCTAssertEqual(urls.trailer(TrailerPlayback(url: "/api/trailers/k1.mp4?mk=a%2Bb"))?.absoluteString, "http://tv.test:8420/api/trailers/k1.mp4?mk=a%2Bb")
        XCTAssertEqual(urls.trailer(TrailerPlayback(url: "http://tv.test:8420/api/trailers/k1.mp4?mk=a"))?.absoluteString, "http://tv.test:8420/api/trailers/k1.mp4?mk=a")
        XCTAssertNil(urls.trailer(TrailerPlayback(url: "")))
        XCTAssertNil(urls.trailer(TrailerPlayback(url: "javascript:alert(1)")))
    }

    func testPlayRequest() async throws {
        let transport = MockTransport { _ in .json(#"{"url":"/api/trailers/k1.mp4?mk=m","durationMs":1000}"#) }
        let client = APIClient(baseURL: base, token: "t", transport: transport)
        let playback = try await client.playTrailer(Trailer(name: "A", key: "k1", play: "/api/trailers/k1/play"))
        XCTAssertEqual(playback.url, "/api/trailers/k1.mp4?mk=m")
        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.pathAndQuery, "/api/trailers/k1/play")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer t")
        XCTAssertNil(request.httpBody)
        XCTAssertGreaterThanOrEqual(request.timeoutInterval, 60, "a first fetch can take a minute")
    }

    func testWithoutPlayNothingIsSent() async {
        let transport = MockTransport { _ in .json("{}") }
        let client = APIClient(baseURL: base, token: "t", transport: transport)
        do {
            _ = try await client.playTrailer(Trailer(name: "A", key: "k1"))
            XCTFail("expected an error")
        } catch {}
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testBusyServerIsAskedAgainAfterRetryAfter() async throws {
        let attempts = Locked(0)
        let transport = MockTransport { _ in
            let n = attempts.withLock { value -> Int in value += 1; return value }
            return n < 3
                ? .json(#"{"error":"busy"}"#, status: 503, headers: ["Retry-After": "4"])
                : .json(#"{"url":"/api/trailers/k1.mp4?mk=m","durationMs":1}"#)
        }
        let client = APIClient(baseURL: base, token: "t", transport: transport)
        let slept = Locked<[Double]>([])
        let playback = try await client.playTrailer(Trailer(name: "A", key: "k1", play: "/api/trailers/k1/play")) { seconds in
            slept.withLock { $0.append(seconds) }
        }
        XCTAssertEqual(playback.url, "/api/trailers/k1.mp4?mk=m")
        XCTAssertEqual(slept.current, [4, 4])
        XCTAssertEqual(transport.requests.count, 3)
    }

    func testBusyRetriesStopAfterAbout30Seconds() async throws {
        let transport = MockTransport { _ in .json(#"{"error":"busy"}"#, status: 503, headers: ["Retry-After": "10"]) }
        let client = APIClient(baseURL: base, token: "t", transport: transport)
        let slept = Locked<[Double]>([])
        do {
            _ = try await client.playTrailer(Trailer(name: "A", key: "k1", play: "/api/trailers/k1/play")) { seconds in
                slept.withLock { $0.append(seconds) }
            }
            XCTFail("expected an error")
        } catch let error as APIError {
            XCTAssertEqual(error.statusCode, 503)
        }
        XCTAssertEqual(slept.current, [10, 10, 10], "30 s in all")
        XCTAssertEqual(transport.requests.count, 4)
    }

    func testRetryAfterIsClamped() async throws {
        XCTAssertEqual(APIClient.busyDelay(.server(status: 503, message: nil, code: nil, retryAfter: 0)), 1)
        XCTAssertEqual(APIClient.busyDelay(.server(status: 503, message: nil, code: nil, retryAfter: 120)), 10)
        XCTAssertEqual(APIClient.busyDelay(.server(status: 503, message: nil, code: nil, retryAfter: nil)), 2)
    }

    func testFetchFailureAndUnknownKeyAreNotRetried() async throws {
        for status in [502, 404] {
            let transport = MockTransport { _ in .json(#"{"error":"Could not fetch the trailer"}"#, status: status, headers: ["Retry-After": "1"]) }
            let client = APIClient(baseURL: base, token: "t", transport: transport)
            do {
                _ = try await client.playTrailer(Trailer(name: "A", key: "k1", play: "/api/trailers/k1/play")) { _ in
                    XCTFail("\(status) must not be retried")
                }
                XCTFail("expected an error")
            } catch let error as APIError {
                XCTAssertEqual(error.statusCode, status)
                XCTAssertEqual(error.serverMessage, "Could not fetch the trailer", "the server's translated message")
            }
            XCTAssertEqual(transport.requests.count, 1)
        }
    }
}
