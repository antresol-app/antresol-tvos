import Foundation
import XCTest
@testable import AntresolKit

/// Which addresses are tried, in which order, and which would send the password in the clear.
final class ServerAddressTests: XCTestCase {
    private func candidates(_ input: String) -> [String] {
        ServerAddress.candidates(for: input).map(\.absoluteString)
    }

    func testHomeNetworkAddressesAreTriedOverHttpOnly() {
        XCTAssertEqual(candidates("192.168.1.10"), ["http://192.168.1.10:8420"])
        XCTAssertEqual(candidates("10.0.0.2:9000"), ["http://10.0.0.2:9000"])
        XCTAssertEqual(candidates("172.20.0.1"), ["http://172.20.0.1:8420"])
        XCTAssertEqual(candidates("169.254.3.4"), ["http://169.254.3.4:8420"])
        XCTAssertEqual(candidates("100.101.102.103"), ["http://100.101.102.103:8420"])
        XCTAssertEqual(candidates("nas"), ["http://nas:8420"])
        XCTAssertEqual(candidates("nas.local:9000"), ["http://nas.local:9000"])
        XCTAssertEqual(candidates("media.lan"), ["http://media.lan:8420"])
        XCTAssertEqual(candidates("[fd00::5]"), ["http://[fd00::5]:8420"])
    }

    func testPublicHostWithoutSchemeTriesHttpsFirst() {
        XCTAssertEqual(candidates("media.example.com"), ["https://media.example.com", "http://media.example.com:8420"])
        XCTAssertEqual(candidates("media.example.com/api/"), ["https://media.example.com", "http://media.example.com:8420"])
        XCTAssertEqual(candidates("media.example.com:9000"), ["https://media.example.com:9000", "http://media.example.com:9000"])
        // the default port, typed on purpose, goes with https too (an https server may listen on it)
        XCTAssertEqual(candidates("media.example.com:8420"), ["https://media.example.com:8420", "http://media.example.com:8420"])
        XCTAssertEqual(candidates(" media.example.com:8420/ "), ["https://media.example.com:8420", "http://media.example.com:8420"])
        XCTAssertEqual(candidates("172.32.0.1"), ["https://172.32.0.1", "http://172.32.0.1:8420"])
        XCTAssertEqual(candidates("100.128.0.1"), ["https://100.128.0.1", "http://100.128.0.1:8420"])
    }

    func testATypedSchemeIsKept() {
        XCTAssertEqual(candidates("http://media.example.com"), ["http://media.example.com"])
        XCTAssertEqual(candidates("https://media.example.com/"), ["https://media.example.com"])
        XCTAssertEqual(candidates("http://192.168.1.10:8420"), ["http://192.168.1.10:8420"])
    }

    func testNotAnAddressHasNoCandidates() {
        XCTAssertEqual(candidates(""), [])
        XCTAssertEqual(candidates("two words"), [])
        XCTAssertEqual(candidates("ftp://x"), [])
    }

    func testOnlyPlainHttpAwayFromHomeIsUnencryptedRemote() throws {
        func remote(_ text: String) throws -> Bool {
            ServerAddress.isUnencryptedRemote(try XCTUnwrap(URL(string: text)))
        }
        XCTAssertTrue(try remote("http://media.example.com"))
        XCTAssertTrue(try remote("http://8.8.8.8:8420"))
        XCTAssertTrue(try remote("http://[2001:db8::1]:8420"))
        XCTAssertFalse(try remote("https://media.example.com"))
        XCTAssertFalse(try remote("http://192.168.1.10:8420"))
        XCTAssertFalse(try remote("http://localhost:8420"))
        XCTAssertFalse(try remote("http://127.0.0.1:8420"))
        XCTAssertFalse(try remote("http://nas.local:8420"))
        XCTAssertFalse(try remote("http://[fe80::1]:8420"))
    }

    // MARK: Connecting: which failure the viewer is told

    /// An attempt that records the URL it was asked and fails with `failures[n]` for the nth one (the
    /// last answers when it runs out), or answers when `failures` is empty.
    private final class Attempts: @unchecked Sendable {
        private(set) var urls: [String] = []
        private let failures: [Error]
        private let answeringFrom: Int

        /// Fails with the given errors in turn, then answers.
        init(failing failures: [Error]) {
            self.failures = failures
            answeringFrom = failures.count
        }

        func callAsFunction(_ url: URL) async throws -> String {
            urls.append(url.absoluteString)
            if urls.count <= answeringFrom { throw failures[urls.count - 1] }
            return "server at \(url.absoluteString)"
        }
    }

    private let noSuchHost = APIError.transport("A server with the specified hostname could not be found.", hostUnreachable: true)
    private let refused = APIError.transport("Could not connect to the server.")

    private func connect(_ input: String, allowing: Bool = false, _ attempts: Attempts) async throws -> (url: URL, connection: String) {
        try await ServerAddress.connect(to: input, allowUnencrypted: allowing) { try await attempts($0) }
    }

    func testAHostThatDoesNotResolveIsAnsweredWithItsFailureBeforeAnyPlainHttp() async {
        let attempts = Attempts(failing: [noSuchHost])
        do {
            _ = try await connect("media.example.com", attempts)
            XCTFail("connected")
        } catch let error as APIError {
            XCTAssertEqual(error, noSuchHost, "the viewer is told the host cannot be reached, not asked to accept plain http")
        } catch {
            XCTFail("\(error)")
        }
        XCTAssertEqual(attempts.urls, ["https://media.example.com"], "no plain-http request before the viewer agreed")
    }

    func testAnUnreachableHostEndsTheTriesAfterConsentToo() async {
        let attempts = Attempts(failing: [noSuchHost])
        do {
            _ = try await connect("media.example.com", allowing: true, attempts)
            XCTFail("connected")
        } catch {
            XCTAssertEqual(error as? APIError, noSuchHost)
        }
        XCTAssertEqual(attempts.urls, ["https://media.example.com"], "http would not resolve either")
    }

    func testARefusedHttpsStillAsksBeforePlainHttp() async {
        let attempts = Attempts(failing: [refused])
        do {
            _ = try await connect("media.example.com", attempts)
            XCTFail("connected")
        } catch {
            XCTAssertTrue(error is UnencryptedConnection, "got \(error)")
        }
        XCTAssertEqual(attempts.urls, ["https://media.example.com"])
    }

    func testPlainHttpIsTriedAfterConsent() async throws {
        let attempts = Attempts(failing: [refused])
        let reached = try await connect("media.example.com", allowing: true, attempts)
        XCTAssertEqual(reached.url.absoluteString, "http://media.example.com:8420")
        XCTAssertEqual(attempts.urls, ["https://media.example.com", "http://media.example.com:8420"])
    }

    func testAnswersOnNeitherSchemeShowTheLastFailureAfterConsent() async {
        let nonsense = APIError.decoding("not json")
        let attempts = Attempts(failing: [refused, nonsense])
        do {
            _ = try await connect("media.example.com", allowing: true, attempts)
            XCTFail("connected")
        } catch {
            XCTAssertEqual(error as? APIError, nonsense, "the plain-http attempt's failure is the answer")
        }
        XCTAssertEqual(attempts.urls.count, 2)
    }

    func testAHomeAddressNeedsNoConsentAndAnUnresolvedNameIsItsFailure() async {
        let attempts = Attempts(failing: [noSuchHost])
        do {
            _ = try await connect("nas.local", attempts)
            XCTFail("connected")
        } catch {
            XCTAssertEqual(error as? APIError, noSuchHost)
        }
        XCTAssertEqual(attempts.urls, ["http://nas.local:8420"])
    }

    func testNotAnAddressFailsAsInvalidWithoutAnAttempt() async {
        let attempts = Attempts(failing: [])
        do {
            _ = try await connect("two words", attempts)
            XCTFail("connected")
        } catch {
            XCTAssertEqual(error as? APIError, .invalidURL("two words"))
        }
        XCTAssertTrue(attempts.urls.isEmpty)
    }

    func testOnlyAnUnresolvedNameOrNoNetworkMarksATransportFailureUnreachable() async {
        struct Failing: HTTPTransport {
            let code: URLError.Code
            func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) { throw URLError(code) }
        }
        func unreachable(_ code: URLError.Code) async -> Bool {
            let client = APIClient(baseURL: URL(string: "https://media.example.com")!, transport: Failing(code: code))
            do {
                _ = try await client.health()
                XCTFail("answered")
                return false
            } catch {
                guard case .transport? = error as? APIError else {
                    XCTFail("not a transport failure: \(error)")
                    return false
                }
                return (error as? APIError)?.isHostUnreachable == true
            }
        }
        for code in [URLError.Code.cannotFindHost, .dnsLookupFailed, .notConnectedToInternet] {
            let marked = await unreachable(code)
            XCTAssertTrue(marked, "\(code)")
        }
        // A refused connection, a timeout and a failed handshake say nothing of the host's other port.
        for code in [URLError.Code.cannotConnectToHost, .timedOut, .networkConnectionLost, .secureConnectionFailed, .serverCertificateUntrusted] {
            let marked = await unreachable(code)
            XCTAssertFalse(marked, "\(code)")
        }
    }
}
