import Foundation
import XCTest
@testable import AntresolKit

/// The TV tab's "Continue" card, the player's mini-guide, the Top Shelf's "On Air Now" and
/// channel links.
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

    // MARK: Mini-guide

    func testStripIsTheCurrentSectionStartingAtTheChannel() {
        let channels = [
            channel(5, 13, "Genres"), channel(1, 1, "Movies"), channel(3, 11, "Genres"),
            channel(2, 10, "Genres"), channel(9, 100, "Series"),
        ]
        let strip = ChannelStrip(current: channels[2], in: channels)
        XCTAssertEqual(strip.category, "Genres")
        XCTAssertEqual(strip.channels.map(\.number), [10, 11, 13])
        XCTAssertEqual(strip.startIndex, 1)
        XCTAssertEqual(strip.current.id, 3)

        XCTAssertEqual(ChannelStrip(current: channels[3], in: channels).startIndex, 0)
        XCTAssertEqual(ChannelStrip(current: channels[0], in: channels).startIndex, 2)
        let alone = ChannelStrip(current: channels[1], in: channels)
        XCTAssertEqual(alone.channels.map(\.id), [1])
    }

    func testStripOfAChannelMissingFromTheList() {
        let gone = channel(42, 42, "Old")
        let strip = ChannelStrip(current: gone, in: [channel(1, 1, "Movies")])
        XCTAssertEqual(strip.channels.map(\.id), [42])
        XCTAssertEqual(strip.startIndex, 0)
        XCTAssertEqual(strip.category, "Old")
        XCTAssertEqual(ChannelStrip(current: gone, in: []).current.id, 42)
    }

    // MARK: Last channel

    func testLastChannelIsKeptPerServerAndProfile() throws {
        let suite = "LiveTVTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = LastChannelStore(defaults: defaults)
        let dad = CredentialKey(serverId: "s1", userId: 1)
        let kid = CredentialKey(serverId: "s1", userId: 2)
        let otherServer = CredentialKey(serverId: "s2", userId: 1)

        XCTAssertNil(store.channelId(for: dad))
        store.remember(3, for: dad)
        store.remember(7, for: kid)
        XCTAssertEqual(store.channelId(for: dad), 3)
        XCTAssertEqual(store.channelId(for: kid), 7)
        XCTAssertNil(store.channelId(for: otherServer))
        store.remember(4, for: dad)
        XCTAssertEqual(LastChannelStore(defaults: defaults).channelId(for: dad), 4, "kept across instances")
        store.forget(for: dad)
        XCTAssertNil(store.channelId(for: dad))
        XCTAssertEqual(store.channelId(for: kid), 7)
    }

    func testLastChannelComesFromTheCurrentList() {
        let fresh = channel(3, 11, now: program(8, from: 0, to: 10))
        let channels = [channel(1, 1), fresh]
        XCTAssertEqual(LastChannelStore.channel(3, in: channels), fresh, "the list's copy, with what is on now")
        XCTAssertNil(LastChannelStore.channel(99, in: channels), "a channel the profile no longer sees")
        XCTAssertNil(LastChannelStore.channel(nil, in: channels))
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
            // Only artwork: the logo picture.
            channel(5, 13, "Genres", now: program(50, from: 1000, to: 1100)),
        ]
        let plan = TopShelfChannels(channels: channels, at: at)
        XCTAssertEqual(plan.entries.map(\.channel.id), [1, 2, 3, 5, 9], "the TV tab's order")
        XCTAssertEqual(plan.entries[0].title, "1 · Channel 1 — P10")
        XCTAssertEqual(plan.entries[0].imagePath, "/b/10")
        XCTAssertEqual(plan.entries[0].progress, 0.5, accuracy: 0.001)
        XCTAssertEqual(plan.entries[0].url.absoluteString, "antresol://channel/1")
        XCTAssertEqual(plan.entries[1].progress, 0.25, accuracy: 0.001)
        XCTAssertEqual(plan.entries[2].program.itemId, 31)
        XCTAssertEqual(plan.entries[3].imagePath, "/api/channels/5/logo.png")
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
            XCTAssertFalse(entry.imagePath.isEmpty)
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
