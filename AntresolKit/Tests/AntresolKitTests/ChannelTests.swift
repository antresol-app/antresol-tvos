import Foundation
import XCTest
@testable import AntresolKit
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class ChannelTests: XCTestCase {
    let base = URL(string: "http://tv.test:8420")!

    private func channel(_ id: Int, _ number: Int, _ category: String = "") -> Channel {
        Channel(id: id, number: number, name: "Channel \(number)", category: category)
    }

    private func program(_ id: Int, from start: TimeInterval, to end: TimeInterval) -> ChannelProgram {
        ChannelProgram(itemId: id, title: "P\(id)", start: Date(timeIntervalSince1970: start), end: Date(timeIntervalSince1970: end))
    }

    func testDecodesTheChannelList() throws {
        let list = try Samples.decode(ChannelList.self, "channels.json")
        XCTAssertEqual(list.channels.count, 6)
        XCTAssertTrue(list.canManage)
        let comedy = list.channels[1]
        XCTAssertEqual(comedy.id, 2)
        XCTAssertEqual(comedy.number, 10)
        XCTAssertEqual(comedy.name, "Комедии")
        XCTAssertEqual(comedy.category, "Кино по жанрам")
        XCTAssertTrue(comedy.auto)
        XCTAssertEqual(comedy.logoPreset, .grad3)
        let now = try XCTUnwrap(comedy.now)
        XCTAssertEqual(now.backdrop, "/api/images/local/1/backdrop")
        XCTAssertEqual(now.year, 1991)
        XCTAssertEqual(now.end.timeIntervalSince(now.start), 90, accuracy: 0.1)
        XCTAssertEqual(comedy.next?.start, now.end)

        let series = try XCTUnwrap(list.channels.last)
        XCTAssertEqual(series.now?.subtitle, "S1 E3 · Серия 3")
        XCTAssertEqual(series.now?.fullTitle, "Тестовый сериал · S1 E3 · Серия 3")
    }

    func testDecodesTheGuide() throws {
        let guide = try Samples.decode(ChannelGuide.self, "channel-guide.json")
        XCTAssertEqual(guide.channel.number, 100)
        XCTAssertEqual(guide.programs.map(\.itemId), [11, 12, 13])
        let during = guide.programs[0].start.addingTimeInterval(10)
        let onAir = guide.onAir(at: during)
        XCTAssertEqual(onAir.now?.itemId, 11)
        XCTAssertEqual(onAir.next?.itemId, 12)
        // The guide moves on by itself between refreshes.
        XCTAssertEqual(guide.onAir(at: guide.programs[1].start).now?.itemId, 12)
        XCTAssertEqual(guide.onAir(at: guide.programs[2].start.addingTimeInterval(1)).next == nil, true)
        // Before the first programme: nothing on, the first is next.
        let early = guide.onAir(at: guide.programs[0].start.addingTimeInterval(-5))
        XCTAssertNil(early.now)
        XCTAssertEqual(early.next?.itemId, 11)
    }

    func testToleratesMissingFields() throws {
        let list = try JSONDecoder().decode(ChannelList.self, from: Data(#"{"channels":[{"id":3,"logo":"x"}]}"#.utf8))
        let channel = try XCTUnwrap(list.channels.first)
        XCTAssertEqual(channel.name, "")
        XCTAssertEqual(channel.logo, 0)
        XCTAssertNil(channel.now)
        XCTAssertFalse(list.canCreate)
        XCTAssertThrowsError(try JSONDecoder().decode(Channel.self, from: Data(#"{"name":"No id"}"#.utf8)))
    }

    func testSectionsAreOrderedByTheirLowestNumber() {
        let channels = [
            channel(1, 40, "Decades"), channel(2, 10, "Genres"), channel(3, 1, "All"),
            channel(4, 11, "Genres"), channel(5, 2, "Decades"), channel(6, 100, "Series"),
        ]
        let sections = ChannelSection.group(channels)
        XCTAssertEqual(sections.map(\.category), ["All", "Decades", "Genres", "Series"])
        XCTAssertEqual(sections[1].channels.map(\.number), [2, 40])
        XCTAssertEqual(sections[2].channels.map(\.number), [10, 11])
        XCTAssertEqual(sections.map(\.id), sections.map(\.category))
        XCTAssertTrue(ChannelSection.group([]).isEmpty)
    }

    func testSampleSections() throws {
        let list = try Samples.decode(ChannelList.self, "channels.json")
        XCTAssertEqual(
            ChannelSection.group(list.channels).map(\.category),
            ["Кино и сериалы", "Кино по жанрам", "Кино по десятилетиям", "Детям", "Сериалы нон-стоп"]
        )
    }

    func testProgress() {
        let p = program(1, from: 1000, to: 1100)
        XCTAssertEqual(p.progress(at: Date(timeIntervalSince1970: 1025)), 0.25, accuracy: 1e-9)
        XCTAssertEqual(p.progress(at: Date(timeIntervalSince1970: 900)), 0)
        XCTAssertEqual(p.progress(at: Date(timeIntervalSince1970: 1200)), 1)
        XCTAssertEqual(program(2, from: 1000, to: 1000).progress(at: Date(timeIntervalSince1970: 1000)), 0)
        XCTAssertTrue(p.isOnAir(at: Date(timeIntervalSince1970: 1000)))
        XCTAssertFalse(p.isOnAir(at: Date(timeIntervalSince1970: 1100)))
        XCTAssertEqual(p.fullTitle, "P1")
    }

    func testProgramAtMovesOnToNext() {
        var c = channel(1, 1)
        c.now = program(1, from: 1000, to: 1100)
        c.next = program(2, from: 1100, to: 1200)
        XCTAssertEqual(c.program(at: Date(timeIntervalSince1970: 1050))?.itemId, 1)
        XCTAssertEqual(c.program(at: Date(timeIntervalSince1970: 1150))?.itemId, 2)
        // Past both (a stale list): the last known programme.
        XCTAssertEqual(c.program(at: Date(timeIntervalSince1970: 1300))?.itemId, 1)
        XCTAssertNil(channel(2, 2).program(at: Date()))
    }

    func testZappingWrapsByNumber() {
        let channels = [channel(7, 100), channel(1, 1), channel(2, 10), channel(3, 11)]
        XCTAssertEqual(Channel.neighbour(of: 2, in: channels, step: 1)?.id, 3)
        XCTAssertEqual(Channel.neighbour(of: 2, in: channels, step: -1)?.id, 1)
        XCTAssertEqual(Channel.neighbour(of: 7, in: channels, step: 1)?.id, 1, "channel up from the last wraps to the first")
        XCTAssertEqual(Channel.neighbour(of: 1, in: channels, step: -1)?.id, 7, "channel down from the first wraps to the last")
        XCTAssertEqual(Channel.neighbour(of: 1, in: channels, step: 5)?.id, 2)
        XCTAssertEqual(Channel.neighbour(of: 1, in: [channel(1, 1)], step: 1)?.id, 1)
        XCTAssertNil(Channel.neighbour(of: 99, in: channels, step: 1))
    }

    func testLogoGradientWraps() {
        XCTAssertEqual(Channel(id: 1, number: 1, name: "", logo: 0).logoPreset, .grad1)
        XCTAssertEqual(Channel(id: 1, number: 1, name: "", logo: 6).logoPreset, .grad7)
        XCTAssertEqual(Channel(id: 1, number: 1, name: "", logo: 7).logoPreset, .grad1)
        XCTAssertEqual(Channel(id: 1, number: 1, name: "", logo: -1).logoPreset, .grad7)
    }

    func testLiveURL() {
        let urls = ServerURLs(baseURL: base)
        XCTAssertEqual(urls.liveChannel(id: 2, mediaKey: "v1.k")?.absoluteString, "http://tv.test:8420/api/channels/live/2/index.m3u8?mk=v1.k")
        XCTAssertEqual(urls.liveChannel(id: 2, mediaKey: nil)?.absoluteString, "http://tv.test:8420/api/channels/live/2/index.m3u8")
    }

    func testRequests() async throws {
        let transport = MockTransport { request in
            switch request.url?.path {
            case "/api/channels": return .json(#"{"channels":[{"id":1,"number":1,"name":"A"}]}"#)
            default: return .json(#"{"channel":{"id":1},"programs":[]}"#)
            }
        }
        let client = APIClient(baseURL: base, token: "t", transport: transport)
        let list = try await client.channels()
        XCTAssertEqual(list.channels.map(\.name), ["A"])
        let guide = try await client.channelGuide(id: 1)
        XCTAssertTrue(guide.programs.isEmpty)
        XCTAssertEqual(transport.requests.map(\.pathAndQuery), ["/api/channels", "/api/channels/1/guide?hours=6"])
        XCTAssertEqual(transport.requests[0].value(forHTTPHeaderField: "Authorization"), "Bearer t")
    }

    func testStartingChannelIsRetried() async throws {
        let attempts = Locked(0)
        let transport = MockTransport { _ in
            let n = attempts.withLock { $0 += 1; return $0 }
            if n < 3 {
                return .json(#"{"error":"Канал запускается — повторите через пару секунд"}"#, status: 503, headers: ["Retry-After": "0.5"])
            }
            return Reply(status: 200, body: Data("#EXTM3U\n".utf8), headers: ["Content-Type": "application/vnd.apple.mpegurl"])
        }
        let client = APIClient(baseURL: base, token: "t", transport: transport)
        let waits = Locked(0)
        let url = try await client.startLiveChannel(id: 2, mediaKey: "k") { waits.withLock { $0 += 1 } }
        XCTAssertEqual(url.absoluteString, "http://tv.test:8420/api/channels/live/2/index.m3u8?mk=k")
        XCTAssertEqual(attempts.current, 3)
        XCTAssertEqual(waits.current, 2)
        XCTAssertEqual(transport.requests.last?.pathAndQuery, "/api/channels/live/2/index.m3u8?mk=k")
    }

    func testBusyAndForbiddenChannelsAreNotRetried() async {
        for (status, retryAfter, message) in [(503, "30", "Сейчас идёт слишком много каналов — попробуйте позже"), (403, "", "Время экрана на сегодня закончилось"), (503, "", "На канале сейчас нечего показывать")] {
            let transport = MockTransport { _ in
                .json(#"{"error":"\#(message)"}"#, status: status, headers: retryAfter.isEmpty ? [:] : ["Retry-After": retryAfter])
            }
            let client = APIClient(baseURL: base, token: "t", transport: transport)
            do {
                _ = try await client.startLiveChannel(id: 2, mediaKey: "k")
                XCTFail("expected \(status)")
            } catch {
                XCTAssertEqual((error as? APIError)?.serverMessage, message)
                XCTAssertEqual(transport.requests.count, 1, message)
            }
        }
    }

    func testRetryGivesUpAfterMaxAttempts() async {
        let transport = MockTransport { _ in .json(#"{"error":"starting"}"#, status: 503, headers: ["Retry-After": "0.5"]) }
        let client = APIClient(baseURL: base, token: "t", transport: transport)
        do {
            _ = try await client.startLiveChannel(id: 2, mediaKey: nil, maxAttempts: 2)
            XCTFail("expected 503")
        } catch {
            XCTAssertEqual((error as? APIError)?.statusCode, 503)
            XCTAssertEqual(transport.requests.count, 2)
        }
    }

    func testRetryDelay() {
        XCTAssertEqual(LiveChannelStart.retryDelay(after: .server(status: 503, message: nil, code: nil, retryAfter: 2)), 2)
        XCTAssertEqual(LiveChannelStart.retryDelay(after: .server(status: 503, message: nil, code: nil, retryAfter: 0)), 0.5)
        XCTAssertNil(LiveChannelStart.retryDelay(after: .server(status: 503, message: nil, code: nil, retryAfter: 30)))
        XCTAssertNil(LiveChannelStart.retryDelay(after: .server(status: 503, message: nil, code: nil, retryAfter: nil)))
        XCTAssertNil(LiveChannelStart.retryDelay(after: .server(status: 404, message: nil, code: nil, retryAfter: 2)))
        XCTAssertNil(LiveChannelStart.retryDelay(after: .unauthorized(message: nil)))
    }
}

private typealias Reply = MockTransport.Reply
