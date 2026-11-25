import Foundation
import XCTest
@testable import AntresolKit

/// A kid asks a parent for what the library lacks: the server's `/api/requests…` as the web uses them.
final class KidRequestTests: XCTestCase {
    private let base = URL(string: "http://tv.test:8420")!

    private func client(_ transport: MockTransport) -> APIClient {
        APIClient(baseURL: base, token: "t", language: "ru", transport: transport)
    }

    static let found = #"""
    [{"kind":"movie","tmdbId":603,"extId":"","title":"Матрица","subtitle":"","year":1999,"poster":"https://image.tmdb.org/t/p/w342/a.jpg",
      "explicit":false,"aliases":[],"kidRequest":{"key":"tmdb:603","allowed":true,"request":null}},
     {"kind":"series","tmdbId":1399,"title":"Игра","year":0,"poster":"","aliases":[],
      "kidRequest":{"key":"tmdb:1399","allowed":true,"request":{"id":7,"key":"tmdb:1399","kind":"series","tmdbId":1399,"title":"Игра",
        "status":"declined","reason":"Слишком страшно","libraryItemId":null,"createdAt":"2026-11-25T10:00:00Z"}}},
     {"kind":"music","tmdbId":0,"extId":"mb-1","title":"Abbey Road","subtitle":"The Beatles","year":1969,"aliases":["Abbey Rd"],
      "kidRequest":{"key":"ext:mb-1","allowed":false,"blocked":"Недоступно","request":null}},
     {"kind":"","title":"no kind"},
     {"kind":"movie","title":"   "}]
    """#

    func testCandidatesDecodeAndTheBrokenOnesAreDropped() async throws {
        let transport = MockTransport { _ in .json(Self.found) }
        let list = try await client(transport).requestSearch("матрица", kind: .video)
        XCTAssertEqual(list.map(\.title), ["Матрица", "Игра", "Abbey Road"])
        XCTAssertTrue(list[0].isVideo)
        XCTAssertEqual(list[0].tmdbId, 603)
        XCTAssertEqual(list[0].kidRequest, RequestState(key: "tmdb:603"))
        XCTAssertNil(list[1].year, "a year of 0 is none")
        let asked = try XCTUnwrap(list[1].kidRequest?.request)
        XCTAssertEqual(asked.status, .declined)
        XCTAssertEqual(asked.reason, "Слишком страшно")
        XCTAssertNil(asked.libraryItemId)
        XCTAssertEqual(asked.createdAt, Timestamp.parse("2026-11-25T10:00:00Z"))
        XCTAssertEqual(asked.slot, "series|tmdb:1399")
        // an album: named by the catalogue, refused by the server for this profile
        XCTAssertFalse(list[2].isVideo)
        XCTAssertEqual(list[2].extId, "mb-1")
        XCTAssertEqual(list[2].kidRequest?.allowed, false)
        XCTAssertEqual(list[2].kidRequest?.blocked, "Недоступно")
        let seen = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(seen.httpMethod, "GET")
        XCTAssertEqual(seen.pathAndQuery, "/api/requests/search?q=%D0%BC%D0%B0%D1%82%D1%80%D0%B8%D1%86%D0%B0&kind=video")
    }

    func testStatusesAndAnUnknownOneIsStillOpen() throws {
        func status(_ s: String) throws -> KidRequest.Status {
            try JSONDecoder().decode(KidRequest.self, from: Data(#"{"id":1,"key":"k","kind":"movie","status":"\#(s)"}"#.utf8)).status
        }
        XCTAssertEqual(try status("pending"), .pending)
        XCTAssertEqual(try status("approved"), .approved)
        XCTAssertEqual(try status("declined"), .declined)
        XCTAssertEqual(try status("in_library"), .inLibrary)
        XCTAssertEqual(try status("later"), .pending)
        let hidden = try JSONDecoder().decode(KidRequest.self, from: Data(#"{"id":2,"key":"k","kind":"movie","title":"","hidden":true,"status":"pending"}"#.utf8))
        XCTAssertTrue(hidden.hidden)
    }

    func testAskBodiesCarryOnlyWhatTheTitleNeeds() throws {
        let movie = KidCandidate(kind: "movie", tmdbId: 603, title: "Матрица", year: 1999, poster: "https://x/a.jpg").ask
        XCTAssertEqual(movie, KidRequestAsk(kind: "movie", tmdbId: 603, title: "Матрица"))
        let album = KidCandidate(kind: "music", extId: "mb-1", title: "Abbey Road", subtitle: "The Beatles", year: 1969, aliases: ["Abbey Rd"]).ask
        XCTAssertEqual(album, KidRequestAsk(kind: "music", extId: "mb-1", title: "Abbey Road", subtitle: "The Beatles", year: 1969, aliases: ["Abbey Rd"]))
        XCTAssertNil(KidCandidate(kind: "comic", extId: "c1", title: "Берсерк", subtitle: "Миура").ask.subtitle, "a manga has no author line")
        let body = try JSONSerialization.jsonObject(with: JSONEncoder().encode(movie)) as? [String: Any]
        XCTAssertEqual(Set(body?.keys ?? [:].keys), ["kind", "tmdbId", "title"])
    }

    func testAskPostsTheRequestAndReturnsIt() async throws {
        let transport = MockTransport { _ in
            .json(#"{"id":9,"key":"tmdb:603","kind":"movie","tmdbId":603,"title":"Матрица","status":"pending","createdAt":"2026-11-25T10:00:00Z"}"#)
        }
        let made = try await client(transport).askRequest(KidRequestAsk(kind: "movie", tmdbId: 603, title: "Матрица"))
        XCTAssertEqual(made.id, 9)
        XCTAssertEqual(made.status, .pending)
        let seen = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(seen.httpMethod, "POST")
        XCTAssertEqual(seen.pathAndQuery, "/api/requests")
        XCTAssertEqual(seen.bodyJSON?["tmdbId"] as? Int, 603)
        XCTAssertEqual(seen.value(forHTTPHeaderField: "Authorization"), "Bearer t")
    }

    func testAnAskAboveTheAgeLimitKeepsTheServersWordsAndCode() async throws {
        let transport = MockTransport { _ in
            .json(#"{"error":"Это 16+, а в твоём профиле можно до 12+","code":"rating"}"#, status: 403)
        }
        do {
            _ = try await client(transport).askRequest(KidRequestAsk(kind: "movie", tmdbId: 1, title: "X"))
            XCTFail("a refusal must throw")
        } catch let error as APIError {
            XCTAssertEqual(error.statusCode, 403)
            XCTAssertEqual(error.code, "rating")
            XCTAssertEqual(error.serverMessage, "Это 16+, а в твоём профиле можно до 12+")
        }
    }

    func testMeAndTheTitlePageCarryTheState() throws {
        let kid = try JSONDecoder().decode(User.self, from: Data(#"{"id":2,"name":"K","avatar":"grad-2","isKid":true,"maxRating":"12+","remote":false,"canRequest":true,"requests":false}"#.utf8))
        XCTAssertTrue(kid.canRequest)
        let adult = try JSONDecoder().decode(User.self, from: Data(#"{"id":1,"name":"A","avatar":"grad-1","isAdmin":true}"#.utf8))
        XCTAssertFalse(adult.canRequest, "an older server, or a profile that cannot ask")
        let again = try JSONDecoder().decode(User.self, from: JSONEncoder().encode(kid))
        XCTAssertTrue(again.canRequest)
        let page = try JSONDecoder().decode(TitleInfo.self, from: Data(#"""
        {"tmdbId":603,"kind":"movie","title":"Матрица","inLibrary":false,"libraryItemId":null,
         "kidRequest":{"key":"tmdb:603","allowed":true,"request":{"id":3,"key":"tmdb:603","kind":"movie","title":"Матрица","status":"pending"}}}
        """#.utf8))
        XCTAssertEqual(page.kidRequest?.request?.status, .pending)
        XCTAssertNil(try JSONDecoder().decode(TitleInfo.self, from: Data(#"{"tmdbId":1,"kind":"movie","title":"A"}"#.utf8)).kidRequest)
    }

    // MARK: The book

    private func request(_ id: Int, _ kind: String = "movie", key: String = "tmdb:1", status: KidRequest.Status = .pending, at: TimeInterval = 0) -> KidRequest {
        KidRequest(id: id, key: key, kind: kind, tmdbId: 1, title: "T\(id)", status: status, createdAt: Date(timeIntervalSince1970: at))
    }

    func testTheBookKeepsTheNewestFirstAndTheNewestAnswerOfATitle() {
        var book = KidRequestBook()
        book.replace(with: [request(1, key: "tmdb:1", at: 100), request(2, "music", key: "ext:a", at: 300), request(3, key: "tmdb:3", at: 200)])
        XCTAssertEqual(book.list.map(\.id), [2, 3, 1])
        // the answer of a new ask is put in at once, over what the page came with
        let state = RequestState(key: "tmdb:1", request: request(1, status: .pending))
        XCTAssertEqual(book.request(kind: "movie", state: state)?.status, .pending)
        book.put(request(1, key: "tmdb:1", status: .approved, at: 100))
        XCTAssertEqual(book.request(kind: "movie", state: state)?.status, .approved)
        XCTAssertNil(book.request(kind: "movie", state: nil))
        XCTAssertNil(book.request(kind: "music", state: RequestState(key: "ext:none")))
        // the page's own request shows until the book knows better
        XCTAssertEqual(book.request(kind: "series", state: RequestState(key: "tmdb:9", request: request(9, "series", key: "tmdb:9")))?.id, 9)
    }

    func testABlockedTitleSaysWhyAndAnAnsweredOneNoLonger() {
        var book = KidRequestBook()
        let allowed = RequestState(key: "tmdb:5")
        XCTAssertNil(book.blockedReason(kind: "movie", state: allowed))
        XCTAssertEqual(book.blockedReason(kind: "music", state: RequestState(key: "ext:x", allowed: false, blocked: "Недоступно")), "Недоступно")
        book.block(slot: "movie|tmdb:5", because: "Это 16+")
        XCTAssertEqual(book.blockedReason(kind: "movie", state: allowed), "Это 16+")
        book.put(request(5, key: "tmdb:5"))
        XCTAssertNil(book.blockedReason(kind: "movie", state: allowed))
    }

    func testTheListSurvivesABrokenEntry() async throws {
        let transport = MockTransport { _ in
            .json(#"[{"id":2,"key":"tmdb:1","kind":"movie","title":"A","status":"approved"},{"nope":true},{"id":1,"key":"ext:x","kind":"music","title":"B","subtitle":"C","status":"in_library","libraryItemId":5}]"#)
        }
        let mine = try await client(transport).myRequests()
        XCTAssertEqual(mine.map(\.status), [.approved, .inLibrary])
        XCTAssertEqual(mine[1].libraryItemId, 5)
        XCTAssertEqual(mine[1].subtitle, "C")
        XCTAssertEqual(transport.requests.first?.pathAndQuery, "/api/requests/mine")
    }

    func testASearchAsksEveryKindAndKeepsTheirOrderWhateverTheAnswersOrder() async {
        let found = await KidRequestBook.candidates(kinds: [.video, .music, .book]) { kind in
            switch kind {
            case .video:
                try await Task.sleep(nanoseconds: 50_000_000)
                return [KidCandidate(kind: "movie", tmdbId: 1, title: "Film")]
            case .music: return [KidCandidate(kind: "music", extId: "a", title: "Album")]
            default: throw APIError.server(status: 403, message: "closed", code: nil, retryAfter: nil)
            }
        }
        XCTAssertEqual(found.map(\.title), ["Film", "Album"], "the slow kind first, the one that failed not at all")
        let none = await KidRequestBook.candidates { _ in [] }
        XCTAssertTrue(none.isEmpty)
        XCTAssertEqual(KidRequestBook.searchKinds, [.video, .music], "the app has no books")
    }
}
