import Foundation
import XCTest
@testable import AntresolKit
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class TVSetupTests: XCTestCase {
    let sid = "0123456789abcdef0123456789abcdef"
    let phone = "192.168.1.23"

    // MARK: link, nonce, addresses, limits

    func testSetupURL() {
        XCTAssertEqual(TVSetupLink.url(host: "192.168.1.50", port: 49152, nonce: "abc_-1"),
                       "http://192.168.1.50:49152/setup?n=abc_-1&v=1")
    }

    func testNonceIs128BitBase64URLAndNewEachTime() {
        let a = TVSetupNonce.make(), b = TVSetupNonce.make()
        XCTAssertEqual(a.value.count, 22, "16 bytes base64url without padding")
        XCTAssertNotEqual(a.value, b.value)
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        XCTAssertTrue(a.value.allSatisfy(allowed.contains), a.value)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let n = TVSetupNonce(value: "x", issuedAt: start)
        XCTAssertFalse(n.isExpired(at: start.addingTimeInterval(599)))
        XCTAssertTrue(n.isExpired(at: start.addingTimeInterval(600)), "10 minutes")
    }

    func testOnlyHomeNetworkClients() {
        for ok in ["192.168.1.5", "10.0.0.1", "172.16.0.1", "172.31.255.255", "169.254.10.1", "127.0.0.1",
                   "::1", "fe80::1%en0", "fd12:3456::1", "::ffff:192.168.1.5", "[fe80::1]"] {
            XCTAssertTrue(LocalAddress.isPrivate(ok), ok)
        }
        for bad in ["8.8.8.8", "172.32.0.1", "172.15.0.1", "192.169.0.1", "2001:db8::1", "::ffff:8.8.8.8", "", "example.com", "1.2.3", "256.1.1.1"] {
            XCTAssertFalse(LocalAddress.isPrivate(bad), bad)
        }
        XCTAssertTrue(LocalAddress.isPrivateIPv4("192.168.1.5"))
        XCTAssertFalse(LocalAddress.isPrivateIPv4("127.0.0.1"), "loopback is not a LAN address")
        XCTAssertFalse(LocalAddress.isPrivateIPv4("fe80::1"))
    }

    func testRateLimitTenPerMinute() {
        var limiter = TVSetupRateLimiter()
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        for i in 0..<10 { XCTAssertTrue(limiter.allow(at: t.addingTimeInterval(Double(i))), "\(i)") }
        XCTAssertFalse(limiter.allow(at: t.addingTimeInterval(30)))
        XCTAssertEqual(limiter.retryAfter(at: t.addingTimeInterval(30)), 30)
        XCTAssertTrue(limiter.allow(at: t.addingTimeInterval(60)), "the first one left the window")
    }

    // MARK: request bodies

    func testJSONSubmission() {
        let body = Data(#"{"n":"nonce1","server":" https://media.example ","serverId":"0123456789ABCDEF0123456789ABCDEF"}"#.utf8)
        XCTAssertEqual(TVSetupSubmission.parse(contentType: "application/json; charset=utf-8", body: body),
                       TVSetupSubmission(nonce: "nonce1", server: "https://media.example", serverId: sid, kind: .json))
        let noId = Data(#"{"n":"nonce1","server":"nas.local"}"#.utf8)
        XCTAssertEqual(TVSetupSubmission.parse(contentType: "application/json", body: noId)?.serverId, nil)
        XCTAssertNil(TVSetupSubmission.parse(contentType: "application/json", body: Data(#"{"n":"x"}"#.utf8)))
        XCTAssertNil(TVSetupSubmission.parse(contentType: "application/json", body: Data("nope".utf8)))
        XCTAssertNil(TVSetupSubmission.parse(contentType: "text/plain", body: body))
    }

    func testFormSubmission() {
        let body = Data("n=abc_-1&server=192.168.1.10%3A8420+".utf8)
        XCTAssertEqual(TVSetupSubmission.parse(contentType: "application/x-www-form-urlencoded", body: body),
                       TVSetupSubmission(nonce: "abc_-1", server: "192.168.1.10:8420", serverId: nil, kind: .form))
        XCTAssertNil(TVSetupSubmission.parse(contentType: "application/x-www-form-urlencoded", body: Data("n=abc&server=".utf8)))
    }

    func testAnswerJSONContract() throws {
        let answer = TVSetupAnswer(code: "ABC234", sid: sid, server: "http://192.168.1.10:8420", device: "Apple TV")
        let object = try JSONSerialization.jsonObject(with: HTTPResponse.json(200, answer).body) as? [String: String]
        XCTAssertEqual(object, ["code": "ABC234", "sid": sid, "server": "http://192.168.1.10:8420", "device": "Apple TV"])
    }

    // MARK: HTTP parsing

    func testParsesARequestOnceItIsWhole() {
        let raw = "POST /setup HTTP/1.1\r\nHost: tv\r\nContent-Type: application/json\r\nContent-Length: 4\r\nAccept-Language: ru-RU,ru;q=0.9\r\n\r\n"
        XCTAssertEqual(HTTPRequest.parse(Data("POST /setup HTTP/1.1\r\nHost".utf8)), .incomplete)
        XCTAssertEqual(HTTPRequest.parse(Data((raw + "{\"a").utf8)), .incomplete)
        guard case .complete(let request) = HTTPRequest.parse(Data((raw + "{\"a\"").utf8)) else { return XCTFail() }
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.path, "/setup")
        XCTAssertEqual(request.body, Data("{\"a\"".utf8))
        XCTAssertTrue(request.prefersRussian)

        guard case .complete(let get) = HTTPRequest.parse(Data("GET /setup?n=x%2Dy&v=1 HTTP/1.1\r\nAccept-Language: en-US,ru\r\n\r\n".utf8)) else { return XCTFail() }
        XCTAssertEqual(get.query, ["n": "x-y", "v": "1"])
        XCTAssertFalse(get.prefersRussian)
    }

    func testRefusesOversizedAndChunkedRequests() {
        XCTAssertEqual(HTTPRequest.parse(Data("POST /setup HTTP/1.1\r\nContent-Length: 4097\r\n\r\n".utf8)), .invalid(status: 413))
        XCTAssertEqual(HTTPRequest.parse(Data("POST /setup HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n".utf8)), .invalid(status: 411))
        XCTAssertEqual(HTTPRequest.parse(Data(String(repeating: "a", count: 9000).utf8)), .invalid(status: 431))
        XCTAssertEqual(HTTPRequest.parse(Data("garbage\r\n\r\n".utf8)), .invalid(status: 400))
    }

    // MARK: handler

    func testGetShowsTheFormForTheLiveNonceOnly() async {
        let (handler, _) = makeHandler()
        let page = await handler.respond(to: get("/setup", n: "live-nonce", ru: true), from: phone)
        XCTAssertEqual(page.status, 200)
        let html = String(decoding: page.body, as: UTF8.self)
        XCTAssertTrue(html.contains("Адрес сервера Antresol"))
        XCTAssertTrue(html.contains(#"name="n" value="live-nonce""#))
        XCTAssertTrue(html.contains("192.168.1.10:8420"))

        let stale = await handler.respond(to: get("/setup", n: "other", ru: true), from: phone)
        XCTAssertEqual(stale.status, 404)
        XCTAssertTrue(String(decoding: stale.body, as: UTF8.self).contains("Код устарел — откройте настройку на телевизоре заново"))
        let english = await handler.respond(to: get("/setup", n: "other", ru: false), from: phone)
        XCTAssertTrue(String(decoding: english.body, as: UTF8.self).contains("Open the setup on the TV again"))
        let other = await handler.respond(to: get("/elsewhere", n: "live-nonce", ru: false), from: phone)
        XCTAssertEqual(other.status, 404)
    }

    func testRefusesClientsOutsideTheHomeNetwork() async {
        let (handler, calls) = makeHandler()
        let response = await handler.respond(to: postJSON(#"{"n":"live-nonce","server":"nas.local"}"#), from: "8.8.8.8")
        XCTAssertEqual(response.status, 403)
        XCTAssertEqual(calls.current.count, 0)
    }

    func testJSONSetupAnswersTheCodeAndUsesTheNonceUp() async throws {
        let (handler, calls) = makeHandler()
        let response = await handler.respond(to: postJSON(#"{"n":"live-nonce","server":"192.168.1.10","serverId":"\#(sid)"}"#), from: phone)
        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(try JSONDecoder().decode(TVSetupAnswer.self, from: response.body),
                       TVSetupAnswer(code: "ABC234", sid: sid, server: "http://192.168.1.10:8420", device: "Apple TV"))
        XCTAssertEqual(calls.current.map(\.0), [URL(string: "http://192.168.1.10:8420")!], "normalised as a typed address")
        XCTAssertEqual(calls.current.map(\.1), [sid])

        let again = await handler.respond(to: postJSON(#"{"n":"live-nonce","server":"192.168.1.10"}"#), from: phone)
        XCTAssertEqual(again.status, 404, "single use")
        XCTAssertEqual(try errorCode(again), "expired_nonce")
        let page = await handler.respond(to: get("/setup", n: "live-nonce", ru: false), from: phone)
        XCTAssertEqual(page.status, 404)
    }

    func testFormSetupRedirectsToTheServersApprovalPage() async {
        let (handler, _) = makeHandler()
        var request = HTTPRequest(method: "POST", path: "/setup", headers: ["content-type": "application/x-www-form-urlencoded"],
                                  body: Data("n=live-nonce&server=192.168.1.10".utf8))
        request.headers["accept-language"] = "ru"
        let response = await handler.respond(to: request, from: phone)
        XCTAssertEqual(response.status, 303)
        XCTAssertEqual(response.header("Location"), "http://192.168.1.10:8420/pair?code=ABC234&sid=\(sid)")
    }

    func testFailuresKeepTheNonceForAnotherTry() async throws {
        let (handler, _) = makeHandler(results: [.failure(TVSetupFailure.serverMismatch), .failure(APIError.transport("down")),
                                                 .failure(APIError.decoding("html")), .success(())])
        let mismatch = await handler.respond(to: postJSON(#"{"n":"live-nonce","server":"nas.local","serverId":"\#(sid)"}"#), from: phone)
        XCTAssertEqual(mismatch.status, 409)
        XCTAssertEqual(try errorCode(mismatch), "server_mismatch")
        let down = await handler.respond(to: postJSON(#"{"n":"live-nonce","server":"nas.local"}"#), from: phone)
        XCTAssertEqual(down.status, 502)
        XCTAssertEqual(try errorCode(down), "unreachable")
        let html = await handler.respond(to: postJSON(#"{"n":"live-nonce","server":"example.org"}"#), from: phone)
        XCTAssertEqual(html.status, 422)
        XCTAssertEqual(try errorCode(html), "not_antresol")
        let bad = await handler.respond(to: postJSON(#"{"n":"live-nonce","server":"ftp://x"}"#), from: phone)
        XCTAssertEqual(bad.status, 400)
        XCTAssertEqual(try errorCode(bad), "bad_request")
        let ok = await handler.respond(to: postJSON(#"{"n":"live-nonce","server":"nas.local"}"#), from: phone)
        XCTAssertEqual(ok.status, 200)
    }

    func testAFailedFormShowsThePageAgainWithTheMessage() async {
        let (handler, _) = makeHandler(results: [.failure(APIError.transport("down"))])
        let request = HTTPRequest(method: "POST", path: "/setup", headers: ["content-type": "application/x-www-form-urlencoded"],
                                  body: Data("n=live-nonce&server=nas.local".utf8))
        let response = await handler.respond(to: request, from: phone)
        XCTAssertEqual(response.status, 502)
        let html = String(decoding: response.body, as: UTF8.self)
        XCTAssertTrue(html.contains("The TV can&#39;t reach the server"))
        XCTAssertTrue(html.contains(#"value="live-nonce""#), "the form is there for another try")
    }

    func testNonceExpiresAfterTenMinutes() async throws {
        let clock = FakeClock()
        let (handler, _) = makeHandler(clock: clock)
        clock.advance(600)
        let response = await handler.respond(to: postJSON(#"{"n":"live-nonce","server":"nas.local"}"#), from: phone)
        XCTAssertEqual(response.status, 404)
        XCTAssertEqual(try errorCode(response), "expired_nonce")
    }

    func testTenRequestsAMinute() async throws {
        let (handler, _) = makeHandler()
        for _ in 0..<10 {
            let page = await handler.respond(to: get("/setup", n: "live-nonce", ru: false), from: phone)
            XCTAssertEqual(page.status, 200)
        }
        let limited = await handler.respond(to: postJSON(#"{"n":"live-nonce","server":"nas.local"}"#), from: phone)
        XCTAssertEqual(limited.status, 429)
        XCTAssertEqual(try errorCode(limited), "rate_limited")
        XCTAssertNotNil(limited.header("Retry-After"))
    }

    func testOnlySetupRequestsCount() async {
        let (handler, _) = makeHandler()
        for _ in 0..<20 {
            let icon = await handler.respond(to: get("/favicon.ico", n: "", ru: false), from: phone)
            XCTAssertEqual(icon.status, 404)
        }
        let page = await handler.respond(to: get("/setup", n: "live-nonce", ru: false), from: phone)
        XCTAssertEqual(page.status, 200, "a browser's favicon requests do not use up the limit")
    }

    func testErrorBodiesAreJustTheCode() async throws {
        let (handler, _) = makeHandler()
        let response = await handler.respond(to: postJSON(#"{"n":"stale","server":"nas.local"}"#), from: phone)
        XCTAssertEqual(try JSONSerialization.jsonObject(with: response.body) as? [String: String], ["error": "expired_nonce"])
    }

    func testFailureCodes() {
        XCTAssertEqual(TVSetupFailure.notSetUp.code, "not_antresol")
        XCTAssertEqual(TVSetupFailure.notSetUp.status, 422)
        XCTAssertTrue(TVSetupFailure.notSetUp.message(russian: true).contains("ещё не настроен"))
        XCTAssertEqual(TVSetupFailure.pairingUnsupported.code, "not_antresol")
        XCTAssertEqual(TVSetupFailure.classify(APIError.transport("x")), .unreachable)
        XCTAssertEqual(TVSetupFailure.classify(APIError.decoding("x")), .notAntresol)
        XCTAssertEqual(TVSetupFailure.classify(APIError.invalidURL("x")), .badRequest)
    }

    func testMalformedPostIsABadRequest() async throws {
        let (handler, _) = makeHandler()
        let response = await handler.respond(to: postJSON(#"{"server":"nas.local"}"#), from: phone)
        XCTAssertEqual(response.status, 400)
        XCTAssertEqual(try errorCode(response), "bad_request")
    }

    func testPairingSessionPollsTheCodeTheSetupStarted() async throws {
        let clock = FakeClock()
        let api = FakePairingAPI(polls: [.approved(token: "tok", user: User(id: 3, name: "Аня", avatar: ""))])
        let ticket = PairingTicket(code: "ABC234", secret: "s", url: "http://x/pair?code=ABC234", expiresAt: clock.now.addingTimeInterval(300), interval: 2, serverId: sid)
        let session = PairingSession(api: api, device: DeviceInfo(id: "a1b2c3d4-0000", name: "Apple TV", model: "", version: ""),
                                     now: { clock.now }, sleep: { clock.advance($0) })
        let states = Locked<[PairingState]>([])
        let result = try await session.run(initial: ticket) { state in states.withLock { $0.append(state) } }
        XCTAssertEqual(result, .approved(token: "tok", user: User(id: 3, name: "Аня", avatar: "")))
        XCTAssertEqual(api.starts, 0, "a second start would cancel the code the phone is approving")
        XCTAssertEqual(states.current.first, .waiting(ticket))
    }

    // MARK: listener on loopback

    #if canImport(Network)
    func testListenerAnswersGetAndPostOnLoopback() async throws {
        let (handler, calls) = makeHandler()
        let listener = TVSetupListener(handler: handler, host: "127.0.0.1")
        let port = try await listener.start()
        defer { listener.stop() }
        XCTAssertGreaterThan(port, 0)
        let base = URL(string: TVSetupLink.url(host: "127.0.0.1", port: port, nonce: "live-nonce"))!

        var get = URLRequest(url: base)
        get.setValue("ru", forHTTPHeaderField: "Accept-Language")
        let (page, pageResponse) = try await URLSession.shared.data(for: get)
        XCTAssertEqual((pageResponse as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertTrue(String(decoding: page, as: UTF8.self).contains("Продолжить"))

        var post = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/setup")!)
        post.httpMethod = "POST"
        post.setValue("application/json", forHTTPHeaderField: "Content-Type")
        post.httpBody = Data(#"{"n":"live-nonce","server":"http://192.168.1.10:8420","serverId":"\#(sid)"}"#.utf8)
        let (body, response) = try await URLSession.shared.data(for: post)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(try JSONDecoder().decode(TVSetupAnswer.self, from: body).code, "ABC234")
        XCTAssertEqual(calls.current.count, 1)

        let (_, again) = try await URLSession.shared.data(for: post)
        XCTAssertEqual((again as? HTTPURLResponse)?.statusCode, 404)
    }
    #endif

    // MARK: helpers

    private func makeHandler(clock: FakeClock = FakeClock(), results: [Result<Void, Error>] = []) -> (TVSetupHandler, Locked<[(URL, String?)]>) {
        let calls = Locked<[(URL, String?)]>([])
        let queue = Locked(results)
        let sid = self.sid
        let handler = TVSetupHandler(nonce: TVSetupNonce(value: "live-nonce", issuedAt: clock.now), now: { clock.now }) { server, serverId in
            calls.withLock { $0.append((server, serverId)) }
            let next = queue.withLock { $0.isEmpty ? Result<Void, Error>.success(()) : $0.removeFirst() }
            try next.get()
            return TVSetupAnswer(code: "ABC234", sid: sid, server: server.absoluteString, device: "Apple TV")
        }
        return (handler, calls)
    }

    private func get(_ path: String, n: String, ru: Bool) -> HTTPRequest {
        HTTPRequest(method: "GET", path: path, query: ["n": n, "v": "1"], headers: ["accept-language": ru ? "ru-RU" : "en-US"])
    }

    private func postJSON(_ json: String) -> HTTPRequest {
        HTTPRequest(method: "POST", path: "/setup", headers: ["content-type": "application/json"], body: Data(json.utf8))
    }

    private func errorCode(_ response: HTTPResponse) throws -> String? {
        (try JSONSerialization.jsonObject(with: response.body) as? [String: Any])?["error"] as? String
    }
}
