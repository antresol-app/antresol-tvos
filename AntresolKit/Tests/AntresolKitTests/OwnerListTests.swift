import Foundation
import XCTest
@testable import AntresolKit
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Watched marks, episode stills, cast portraits and trailers.
final class OwnerListTests: XCTestCase {
    func testCardWatchedAndThumb() throws {
        let json = #"""
        {"items":[
          {"id":1,"kind":"movie","title":"Seen","watched":true},
          {"id":2,"kind":"movie","title":"New"},
          {"id":4,"kind":"episode","title":"E1","poster":"/api/images/local/2/poster","backdrop":"/api/images/local/2/backdrop","thumb":"/api/images/frame/4"}
        ],"total":3}
        """#
        let page = try JSONDecoder().decode(Page<Card>.self, from: Data(json.utf8))
        XCTAssertEqual(page.items.map(\.watched), [true, false, false])
        XCTAssertEqual(page.items[1].thumb, "")
        XCTAssertEqual(page.items[2].thumb, "/api/images/frame/4")
        XCTAssertEqual(page.items[2].wideArtwork, ["/api/images/frame/4", "/api/images/local/2/backdrop", "/api/images/local/2/poster"])
        XCTAssertEqual(page.items[1].wideArtwork.first, "", "no still: the views skip to the backdrop")
    }

    func testCardRoundTripKeepsNewFields() throws {
        let card = Card(id: 7, kind: .episode, title: "E", watched: true, thumb: "/api/images/frame/7")
        let decoded = try JSONDecoder().decode(Card.self, from: JSONEncoder().encode(card))
        XCTAssertEqual(decoded, card)
    }

    func testEpisodeCardWatchedMatchesItsCard() throws {
        let json = #"{"id":4,"kind":"episode","title":"E1","seasonNo":1,"episodeNo":1,"watched":true,"thumb":"/api/images/frame/4"}"#
        let episode = try JSONDecoder().decode(EpisodeCard.self, from: Data(json.utf8))
        XCTAssertTrue(episode.watched)
        XCTAssertTrue(episode.card.watched)
        XCTAssertEqual(episode.card.thumb, "/api/images/frame/4")

        let made = EpisodeCard(card: Card(id: 5, kind: .episode, title: "E2", watched: true), seasonNo: 1, episodeNo: 2)
        XCTAssertTrue(made.watched, "a watched card makes a watched episode")
        let marked = EpisodeCard(card: Card(id: 6, kind: .episode, title: "E3"), seasonNo: 1, episodeNo: 3, watched: true)
        XCTAssertTrue(marked.card.watched)
    }

    func testCastPhoto() throws {
        let json = #"{"id":19,"kind":"movie","title":"M","cast":[{"name":"Ann Example","character":"Lead","photo":"/api/images/cast/Ann%20Example"},{"name":"Bo"}]}"#
        let detail = try JSONDecoder().decode(ItemDetail.self, from: Data(json.utf8))
        XCTAssertEqual(detail.cast.map(\.photo), ["/api/images/cast/Ann%20Example", ""])
        XCTAssertEqual(detail.cast[1].name, "Bo")
    }

    func testTrailersSample() throws {
        let trailers = try Samples.decode(TrailerList.self, "item-trailers.json").trailers
        XCTAssertEqual(trailers.map(\.key), ["dQw4w9WgXcQ", "aqz-KE-bpKQ"])
        XCTAssertTrue(trailers[0].official)
        XCTAssertFalse(trailers[0].isTeaser)
        XCTAssertTrue(trailers[1].isTeaser)
        XCTAssertEqual(trailers[0].appURL?.absoluteString, "youtube://watch/dQw4w9WgXcQ")
        XCTAssertEqual(trailers[0].webURL?.absoluteString, "https://www.youtube.com/watch?v=dQw4w9WgXcQ")
    }

    func testTrailerListIsTolerant() throws {
        let json = #"{"trailers":[{"name":"No key"},{"key":"v1","site":"Vimeo"},{"key":"abc","url":"javascript:alert(1)"}]}"#
        let trailers = try JSONDecoder().decode(TrailerList.self, from: Data(json.utf8)).trailers
        XCTAssertEqual(trailers.map(\.key), ["abc"], "entries without a key and non-YouTube ones are dropped")
        XCTAssertEqual(trailers[0].site, "YouTube")
        XCTAssertEqual(trailers[0].webURL?.absoluteString, "https://www.youtube.com/watch?v=abc", "only an https url is used as is")
        XCTAssertTrue(try JSONDecoder().decode(TrailerList.self, from: Data("{}".utf8)).trailers.isEmpty)
    }

    func testTrailersRequest() async throws {
        let transport = MockTransport { _ in .json(#"{"trailers":[{"key":"k1","name":"T"}]}"#) }
        let client = APIClient(baseURL: URL(string: "http://tv.test:8420")!, token: "t", transport: transport)
        let trailers = try await client.trailers(itemId: 2)
        XCTAssertEqual(trailers.map(\.key), ["k1"])
        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.pathAndQuery, "/api/items/2/trailers")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer t")
    }
}
