import Foundation
import XCTest
@testable import AntresolKit

/// The Top Shelf's "On Air Now", channel links and what is on next.
final class LiveTVTests: XCTestCase {
    private func channel(_ id: Int, _ number: Int, _ category: String = "", now: ChannelProgram? = nil, next: ChannelProgram? = nil) -> Channel {
        Channel(id: id, number: number, name: "Channel \(number)", category: category, now: now, next: next)
    }

    private func program(_ id: Int, from start: TimeInterval, to end: TimeInterval, backdrop: String = "", poster: String = "") -> ChannelProgram {
        ChannelProgram(
            itemId: id, title: "P\(id)", start: Date(timeIntervalSince1970: start), end: Date(timeIntervalSince1970: end),
            poster: poster, backdrop: backdrop
        )
    }

    // MARK: Up next

    func testUpNext() {
        let c = channel(1, 1, now: program(1, from: 1000, to: 1100), next: program(2, from: 1100, to: 1200))
        XCTAssertEqual(c.upNext(at: Date(timeIntervalSince1970: 1050))?.itemId, 2)
        // `next` is on air (the list is a little stale): nothing known after it.
        XCTAssertNil(c.upNext(at: Date(timeIntervalSince1970: 1150)))
        // Both over.
        XCTAssertNil(c.upNext(at: Date(timeIntervalSince1970: 1300)))
        // Before `now` starts, `next` is still to come.
        XCTAssertEqual(c.upNext(at: Date(timeIntervalSince1970: 900))?.itemId, 2)
        XCTAssertNil(channel(2, 2, now: program(1, from: 1000, to: 1100)).upNext(at: Date(timeIntervalSince1970: 1050)))
        // No `now`, only a future `next`.
        XCTAssertEqual(channel(3, 3, next: program(5, from: 1100, to: 1200)).upNext(at: Date(timeIntervalSince1970: 1050))?.itemId, 5)
    }

    // MARK: Top Shelf

    func testTopShelfChannelsOnAir() {
        let at = Date(timeIntervalSince1970: 1050)
        let channels = [
            channel(9, 100, "Series", now: program(90, from: 1000, to: 1100, backdrop: "", poster: "/p/90")),
            channel(2, 10, "Genres", now: program(20, from: 1000, to: 1200, backdrop: "/b/20")),
            channel(1, 1, "Movies", now: program(10, from: 1000, to: 1100, backdrop: "/b/10")),
            // Nothing on air: left out.
            channel(4, 12, "Genres"),
            // Moved on to `next` since the list was fetched.
            channel(3, 11, "Genres", now: program(30, from: 900, to: 1000), next: program(31, from: 1000, to: 1100)),
            // No artwork at all: the extension's neutral placeholder.
            channel(5, 13, "Genres", now: program(50, from: 1000, to: 1100)),
        ]
        let plan = TopShelfChannels(channels: channels, at: at)
        XCTAssertEqual(plan.entries.map(\.channel.id), [1, 2, 3, 5, 9], "by number")
        XCTAssertEqual(plan.entries[0].title, "1 · Channel 1 — P10")
        XCTAssertEqual(plan.entries[0].imagePath, "/b/10")
        XCTAssertEqual(plan.entries[0].progress, 0.5, accuracy: 0.001)
        XCTAssertEqual(plan.entries[0].url.absoluteString, "antresol://channel/1")
        XCTAssertEqual(plan.entries[1].progress, 0.25, accuracy: 0.001)
        XCTAssertEqual(plan.entries[2].program.itemId, 31)
        XCTAssertEqual(plan.entries[3].imagePath, "", "never a logo tile")
        XCTAssertEqual(plan.entries[4].imagePath, "/p/90", "the poster when there is no backdrop")
    }

    func testTopShelfChannelsAreLimited() {
        let at = Date(timeIntervalSince1970: 1050)
        let channels = (1...14).map { channel($0, $0, "All", now: program($0, from: 1000, to: 1100)) }
        XCTAssertEqual(TopShelfChannels(channels: channels, at: at).entries.map(\.channel.id), Array(1...10))
        XCTAssertEqual(TopShelfChannels(channels: channels, at: at, limit: 3).entries.count, 3)
        XCTAssertTrue(TopShelfChannels(channels: [], at: at).entries.isEmpty)
    }

    func testTopShelfChannelsFromTheSample() throws {
        let list = try Samples.decode(ChannelList.self, "channels.json")
        let onAir = list.channels.compactMap(\.now).first
        let at = try XCTUnwrap(onAir).start.addingTimeInterval(1)
        let plan = TopShelfChannels(channels: list.channels, at: at)
        XCTAssertFalse(plan.entries.isEmpty)
        for entry in plan.entries {
            XCTAssertTrue(entry.title.hasPrefix("\(entry.channel.number) · \(entry.channel.name) — "))
            XCTAssertEqual(entry.imagePath, entry.program.still)
            XCTAssertEqual(DeepLink(url: entry.url), .channel(id: entry.channel.id))
        }
    }

    // MARK: Links

    func testChannelLinks() {
        XCTAssertEqual(DeepLink(url: URL(string: "antresol://channel/3")!), .channel(id: 3))
        XCTAssertEqual(DeepLink(url: URL(string: "ANTRESOL://Channel/12/")!), .channel(id: 12))
        XCTAssertEqual(DeepLink.channel(id: 3).url.absoluteString, "antresol://channel/3")
        XCTAssertNil(DeepLink.channel(id: 3).itemId)
        XCTAssertEqual(DeepLink.item(id: 4).itemId, 4)
        for string in ["antresol://channel/", "antresol://channel/abc", "antresol://channel/0", "antresol://channel/-2",
                       "antresol://channel/1/2", "antresol://channels/1"] {
            XCTAssertNil(DeepLink(url: URL(string: string)!), string)
        }
    }
}
