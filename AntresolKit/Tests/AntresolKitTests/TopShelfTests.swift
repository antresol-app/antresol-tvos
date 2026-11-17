import Foundation
import XCTest
@testable import AntresolKit

final class DeepLinkTests: XCTestCase {
    func testParsesAndBuildsLinks() {
        XCTAssertEqual(DeepLink(url: URL(string: "antresol://item/19")!), .item(id: 19))
        XCTAssertEqual(DeepLink(url: URL(string: "antresol://play/22")!), .play(id: 22))
        XCTAssertEqual(DeepLink(url: URL(string: "ANTRESOL://Item/7/")!), .item(id: 7))
        XCTAssertEqual(DeepLink.item(id: 19).url.absoluteString, "antresol://item/19")
        XCTAssertEqual(DeepLink.play(id: 22).url.absoluteString, "antresol://play/22")
        XCTAssertEqual(DeepLink.play(id: 22).itemId, 22)
    }

    func testRejectsOtherURLs() {
        for string in ["https://item/19", "antresol://item/", "antresol://item/abc", "antresol://item/0",
                       "antresol://album/3", "antresol://item/1/2", "antresol:item/1"] {
            XCTAssertNil(DeepLink(url: URL(string: string)!), string)
        }
    }
}

final class HomeFilterTests: XCTestCase {
    func testWithoutBooksDropsBookCardsAndEmptiedShelves() throws {
        let home = try Samples.decode(HomeResponse.self, "home.json")
        XCTAssertNotNil(home.shelf(ShelfID.reading))
        let filtered = home.withoutBooks
        XCTAssertNil(filtered.shelf(ShelfID.reading))
        XCTAssertEqual(filtered.shelves.map(\.id), home.shelves.map(\.id).filter { $0 != ShelfID.reading })
        XCTAssertEqual(filtered.shelf(ShelfID.continueWatching)?.cards, home.shelf(ShelfID.continueWatching)?.cards)

        let movie = Card(id: 1, kind: .movie, title: "Movie")
        let mixed = HomeResponse(
            hero: [Card(id: 2, kind: .book, title: "Book"), movie],
            shelves: [Shelf(id: "want", title: "Want To", cards: [Card(id: 3, kind: .comicVolume, title: "Vol"), movie, Card(id: 4, kind: .audiobook, title: "Audio")])]
        ).withoutBooks
        XCTAssertEqual(mixed.hero, [movie])
        XCTAssertEqual(mixed.shelf("want")?.cards, [movie])
    }
}

final class TopShelfPlanTests: XCTestCase {
    func testSectionsFromHome() throws {
        let home = try Samples.decode(HomeResponse.self, "home.json")
        let plan = TopShelfPlan(home: home)
        XCTAssertEqual(plan.sections.map(\.kind), [.continueWatching, .recentlyAdded])

        let continuing = plan.sections[0]
        XCTAssertEqual(continuing.serverTitle, "Continue Watching")
        XCTAssertEqual(continuing.shape, .wide)
        XCTAssertEqual(continuing.entries.map(\.card.id), [19, 22, 12])
        let first = continuing.entries[0]
        XCTAssertEqual(first.imagePath, home.shelf("continue")?.cards[0].backdrop)
        XCTAssertEqual(first.progress ?? 0, 0.333, accuracy: 0.001)
        XCTAssertEqual(first.displayURL, DeepLink.item(id: 19).url)
        XCTAssertEqual(first.playURL, DeepLink.play(id: 19).url)
        // No artwork at all: the tile falls back to the system placeholder.
        XCTAssertNil(continuing.entries[1].imagePath)
        // Episode with a poster but no backdrop uses the poster.
        XCTAssertEqual(continuing.entries[2].imagePath, home.shelf("continue")?.cards[2].poster)
        XCTAssertNil(continuing.entries[2].progress)

        let recent = plan.sections[1]
        XCTAssertNil(recent.serverTitle)
        XCTAssertEqual(recent.shape, .poster)
        // Movies and shows interleaved: first movie, first show, then the other movies.
        XCTAssertEqual(recent.entries.map(\.card.id), [26, 2, 25, 22, 19, 1])
    }

    func testLimitsAndSkipsNonVideoAndEmptyShelves() {
        let movies = (1...20).map { Card(id: $0, kind: .movie, title: "M\($0)") }
        let album = Card(id: 99, kind: .album, title: "Album")
        let home = HomeResponse(hero: [], shelves: [
            Shelf(id: "continue", title: "", cards: [album]),
            Shelf(id: "recent-movies", title: "Recently Added Movies", cards: movies + [movies[0]]),
        ])
        let plan = TopShelfPlan(home: home, maxItemsPerSection: 5)
        XCTAssertEqual(plan.sections.map(\.kind), [.recentlyAdded])
        XCTAssertEqual(plan.sections[0].entries.map(\.card.id), [1, 2, 3, 4, 5])
        XCTAssertTrue(TopShelfPlan(home: HomeResponse(hero: [], shelves: [])).sections.isEmpty)
    }
}

/// The Top Shelf extension titles its sections from `<language>.lproj` of its own bundle,
/// `language` being the session's (`APIClient.normalizeLanguage`: `en` or `ru`). The
/// extension has no test target, so its strings files are read from the checkout.
final class TopShelfStringsTests: XCTestCase {
    private static let keys = ["Continue Watching", "Recently Added", "On Air Now"]

    func testEverySessionLanguageHasItsSectionTitles() throws {
        let english = try strings("en")
        let russian = try strings("ru")
        for key in Self.keys {
            XCTAssertEqual(english[key], key)
            let title = try XCTUnwrap(russian[key], key)
            XCTAssertFalse(title.isEmpty)
            XCTAssertNotEqual(title, key, "\(key) is not translated")
        }
        // What the app stores in the shared session, whatever the language's spelling.
        for language in ["ru", "ru-RU", "en", "en-GB", "de", ""] {
            XCTAssertNoThrow(try strings(APIClient.normalizeLanguage(language)), language)
        }
    }

    /// `TopShelf/<language>.lproj/Localizable.strings` as a dictionary.
    private func strings(_ language: String) throws -> [String: String] {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let file = root.appendingPathComponent("TopShelf/\(language).lproj/Localizable.strings")
        var out: [String: String] = [:]
        for line in try String(contentsOf: file, encoding: .utf8).split(whereSeparator: \.isNewline) {
            let parts = line.components(separatedBy: "\" = \"")
            guard parts.count == 2, parts[0].hasPrefix("\""), parts[1].hasSuffix("\";") else { continue }
            out[String(parts[0].dropFirst())] = String(parts[1].dropLast(2))
        }
        return out
    }
}
