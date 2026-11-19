import Foundation
import XCTest
@testable import AntresolKit

/// «New Releases» (`tracked-new`) as servers write it: a followed title off the library is a TMDB
/// card with id 0 (no `id` is the same), so two of them share kind and id. A row keyed by kind and
/// id holds one identity several times, and opening such a card asks for `/api/items/0`; every
/// screen built on Home, music home and the Top Shelf gets only the cards it can open, each once.
final class OpenableCardsTests: XCTestCase {
    let base = URL(string: "http://tv.test:8420")!

    /// A library show, two titles off the library, one more without an id, and repeats.
    static let homeJSON = """
    {"hero":[{"id":5,"kind":"series","title":"Show"},{"id":5,"kind":"series","title":"Show"},
             {"id":0,"kind":"movie","title":"Far Film"}],
     "shelves":[
      {"id":"continue","title":"Continue","cards":[{"id":7,"kind":"movie","title":"Film","progress":0.4}]},
      {"id":"tracked-new","title":"New Releases","cards":[
        {"id":5,"kind":"series","title":"Show","subtitle":"S2 · E1"},
        {"id":0,"kind":"series","title":"Far Show","tmdbKind":"series","tmdbId":9001,"season":2,"episode":1},
        {"id":0,"kind":"series","title":"Other Far Show","tmdbKind":"series","tmdbId":9002,"season":1,"episode":3},
        {"kind":"movie","title":"Far Film","tmdbKind":"movie","tmdbId":9003}]},
      {"id":"watchlist","title":"Want","cards":[{"id":0,"kind":"movie","title":"Far Film"}]},
      {"id":"recent-movies","title":"Movies","cards":[
        {"id":7,"kind":"movie","title":"Film"},{"id":7,"kind":"movie","title":"Film"},{"id":7,"kind":"episode","title":"E"}]},
      {"id":"recent-series","title":"Series","cards":[{"id":5,"kind":"series","title":"Show"}]}
     ]}
    """

    func testCardWithoutIdDecodesAsOffTheLibrary() throws {
        let card = try JSONDecoder().decode(Card.self, from: Data(#"{"kind":"movie","title":"Far Film"}"#.utf8))
        XCTAssertEqual(card.id, 0)
        XCTAssertEqual(card.title, "Far Film")
        // one such card does not fail the whole response
        let home = try JSONDecoder().decode(HomeResponse.self, from: Data(Self.homeJSON.utf8))
        XCTAssertEqual(home.shelf("tracked-new")?.cards.map(\.id), [5, 0, 0, 0])
    }

    func testHomeKeepsLibraryCardsEachOnce() throws {
        let home = try JSONDecoder().decode(HomeResponse.self, from: Data(Self.homeJSON.utf8)).openable
        XCTAssertEqual(home.hero.map(\.id), [5])
        // "watchlist" held only a title off the library, so it is gone
        XCTAssertEqual(home.shelves.map(\.id), ["continue", "tracked-new", "recent-movies", "recent-series"])
        XCTAssertEqual(home.shelf("tracked-new")?.cards.map(\.id), [5])
        // a movie and an episode of the same id are two cards
        XCTAssertEqual(home.shelf("recent-movies")?.cards.map(\.uniqueKey), ["movie-7", "episode-7"])
        // a shelf that needed nothing removed is the same value
        XCTAssertEqual(home.shelf("continue")?.cards.first?.progress, 0.4)
        for shelf in home.shelves {
            XCTAssertEqual(Set(shelf.cards.map(\.uniqueKey)).count, shelf.cards.count, shelf.id)
            XCTAssertTrue(shelf.cards.allSatisfy { $0.id > 0 }, shelf.id)
        }
    }

    func testClientGivesScreensOnlyOpenableCards() async throws {
        let transport = MockTransport { request in
            switch request.pathAndQuery {
            case "/api/home": return .json(Self.homeJSON)
            case "/api/music/home":
                return .json(#"""
                {"shelves":[{"id":"recent-albums","title":"Albums","cards":[
                   {"id":3,"kind":"album","title":"A"},{"id":3,"kind":"album","title":"A"},{"id":0,"kind":"album","title":"Far"}]},
                 {"id":"artists","title":"Artists","cards":[{"kind":"artist","title":"Far Artist"}]}]}
                """#)
            default: return .json("{}", status: 404)
            }
        }
        let client = APIClient(baseURL: base, token: "t", transport: transport)

        let home = try await client.home()
        XCTAssertEqual(home.shelves.map(\.id), ["continue", "tracked-new", "recent-movies", "recent-series"])
        XCTAssertEqual(home.shelf("tracked-new")?.cards.map(\.id), [5])
        XCTAssertEqual(home.hero.map(\.id), [5])
        // the screens that filter on top of it (no books on Apple TV) see the same cards
        XCTAssertEqual(home.withoutBooks.shelf("tracked-new")?.cards.map(\.id), [5])

        let music = try await client.musicHome()
        XCTAssertEqual(music.shelves.map(\.id), ["recent-albums"])
        XCTAssertEqual(music.shelf("recent-albums")?.cards.map(\.id), [3])
    }

    /// The Top Shelf's links open `antresol://item/<id>`, and id 0 is not a link.
    func testTopShelfHasNoCardOffTheLibrary() async throws {
        let json = """
        {"hero":[],"shelves":[
          {"id":"continue","title":"Continue","cards":[
            {"id":0,"kind":"series","title":"Far Show","progress":0.2},{"id":7,"kind":"movie","title":"Film","progress":0.4},
            {"id":7,"kind":"movie","title":"Film","progress":0.4}]},
          {"id":"recent-movies","title":"Movies","cards":[
            {"id":0,"kind":"movie","title":"Far Film"},{"kind":"movie","title":"Far Film 2"},{"id":8,"kind":"movie","title":"Film 8"}]},
          {"id":"recent-series","title":"Series","cards":[
            {"id":0,"kind":"series","title":"Far Show"},{"id":0,"kind":"series","title":"Other Far Show"},{"id":5,"kind":"series","title":"Show"}]}]}
        """
        let home = try JSONDecoder().decode(HomeResponse.self, from: Data(json.utf8))
        let fromResponse = TopShelfPlan(home: home)

        let client = APIClient(baseURL: base, token: "t", transport: MockTransport { _ in .json(json) })
        let fromClient = TopShelfPlan(home: try await client.home())

        for plan in [fromResponse, fromClient] {
            XCTAssertEqual(plan.sections.map(\.kind), [.continueWatching, .recentlyAdded])
            XCTAssertEqual(plan.sections[0].entries.map(\.card.id), [7])
            XCTAssertEqual(plan.sections[1].entries.map(\.card.id), [8, 5])
            XCTAssertTrue(plan.sections.flatMap(\.entries).allSatisfy { $0.displayURL != DeepLink.item(id: 0).url })
        }
    }
}
