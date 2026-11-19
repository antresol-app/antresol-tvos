import Foundation
import XCTest
@testable import AntresolKit
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class ChannelTests: XCTestCase {
    let base = URL(string: "http://tv.test:8420")!

    private func channel(_ id: Int, _ number: Int, _ category: String = "", favorite: Bool = false) -> Channel {
        Channel(id: id, number: number, name: "Channel \(number)", category: category, favorite: favorite)
    }

    private func program(_ id: Int, from start: TimeInterval, to end: TimeInterval) -> ChannelProgram {
        ChannelProgram(itemId: id, title: "P\(id)", start: Date(timeIntervalSince1970: start), end: Date(timeIntervalSince1970: end))
    }

    func testDecodesTheChannelList() throws {
        let list = try Samples.decode(ChannelList.self, "channels.json")
        XCTAssertEqual(list.channels.map(\.number), [1, 2, 3, 4])
        XCTAssertTrue(list.canManage)
        XCTAssertEqual(list.lastChannel, 2)
        XCTAssertEqual(list.last?.name, "Комедии")
        let drama = list.channels[2]
        XCTAssertEqual(drama.name, "Драмы")
        XCTAssertEqual(drama.category, "Кино по жанрам")
        XCTAssertTrue(drama.favorite)
        XCTAssertFalse(list.channels[0].favorite)
        let now = try XCTUnwrap(list.channels[0].now)
        XCTAssertEqual(now.id, "1-1")
        XCTAssertEqual(now.kind, "movie")
        XCTAssertEqual(now.rating, "12+")
        XCTAssertEqual(now.genres, ["комедия", "приключения"])
        XCTAssertEqual(now.still, "/api/images/local/18/backdrop")
        XCTAssertEqual(now.audio?.map(\.slot), ["ru", "en", "orig"])
        XCTAssertEqual(now.audio?.first?.title, "Русский — LostFilm")
        XCTAssertEqual(now.subtitles?.map(\.name), ["English"])
        // Absent arrays are «unknown», empty ones «none».
        XCTAssertEqual(list.channels[0].next?.audio, [])
        XCTAssertNil(list.channels[0].next?.subtitles)
        XCTAssertNil(list.channels[1].now?.audio)
        XCTAssertEqual(list.channels[0].next?.start, now.end)
    }

    func testDecodesTheGuide() throws {
        let guide = try Samples.decode(ChannelGuide.self, "channel-guide.json")
        XCTAssertEqual(guide.channel.number, 12)
        XCTAssertEqual(guide.programs.count, 3)
        XCTAssertEqual(guide.programs[0].kind, "episode")
        XCTAssertTrue(guide.programs[0].fullTitle.hasPrefix("Смешные соседи · S1 E"))
        let during = guide.programs[0].start.addingTimeInterval(10)
        let onAir = guide.onAir(at: during)
        XCTAssertEqual(onAir.now, guide.programs[0])
        XCTAssertEqual(onAir.next, guide.programs[1])
        // The guide moves on by itself between refreshes.
        XCTAssertEqual(guide.onAir(at: guide.programs[1].start).now, guide.programs[1])
        XCTAssertNil(guide.onAir(at: guide.programs[2].start.addingTimeInterval(1)).next)
        // Before the first programme: nothing on, the first is next.
        let early = guide.onAir(at: guide.programs[0].start.addingTimeInterval(-5))
        XCTAssertNil(early.now)
        XCTAssertEqual(early.next, guide.programs[0])
    }

    func testToleratesMissingFields() throws {
        let list = try JSONDecoder().decode(ChannelList.self, from: Data(#"{"channels":[{"id":3,"logo":"x","now":{"start":"bad"}}]}"#.utf8))
        let channel = try XCTUnwrap(list.channels.first)
        XCTAssertEqual(channel.name, "")
        XCTAssertFalse(channel.favorite)
        XCTAssertEqual(channel.now?.id, "")
        XCTAssertNil(channel.now?.audio)
        XCTAssertNil(list.lastChannel)
        XCTAssertNil(list.last)
        XCTAssertFalse(list.canCreate)
        XCTAssertThrowsError(try JSONDecoder().decode(Channel.self, from: Data(#"{"name":"No id"}"#.utf8)))
    }

    func testTheListKeepsTheServersOrder() throws {
        // «Favourites first»: the server put the starred 7 before 2; the app keeps that.
        let list = try JSONDecoder().decode(ChannelList.self, from: Data(#"{"channels":[{"id":3,"number":7,"favorite":true},{"id":1,"number":2},{"id":9,"number":2}],"lastChannel":42,"favoritesFirst":true}"#.utf8))
        XCTAssertEqual(list.channels.map(\.id), [3, 1, 9])
        XCTAssertTrue(list.favoritesFirst)
        XCTAssertNil(list.last, "a last channel the profile no longer sees")
        let older = try JSONDecoder().decode(ChannelList.self, from: Data(#"{"channels":[]}"#.utf8))
        XCTAssertFalse(older.favoritesFirst, "a server without the setting orders by number")
    }

    func testAStarReordersTheListAsTheServerWould() {
        var list = ChannelList(channels: [channel(5, 5, favorite: true), channel(1, 1), channel(3, 3), channel(8, 8)], favoritesFirst: true)
        list.setFavorite(true, channelId: 8)
        XCTAssertEqual(list.channels.map(\.number), [5, 8, 1, 3], "a new favourite goes up among them, by number")
        list.setFavorite(false, channelId: 5)
        XCTAssertEqual(list.channels.map(\.number), [8, 1, 3, 5], "an unstarred one goes back by number")
        // Without «favourites first» the list stays by number.
        var plain = ChannelList(channels: [channel(1, 1), channel(3, 3)], favoritesFirst: false)
        plain.setFavorite(true, channelId: 3)
        XCTAssertEqual(plain.channels.map(\.number), [1, 3])
        XCTAssertTrue(plain.channels[1].favorite)
        XCTAssertEqual(Channel.listOrder([channel(2, 2), channel(1, 1, favorite: true)], favoritesFirst: false).map(\.id), [1, 2])
    }

    func testChannelPrefs() throws {
        XCTAssertFalse(try JSONDecoder().decode(ChannelPrefs.self, from: Data(#"{"favoritesFirst":false}"#.utf8)).favoritesFirst)
        XCTAssertTrue(try JSONDecoder().decode(ChannelPrefs.self, from: Data("{}".utf8)).favoritesFirst, "the server's default")
        let body = try XCTUnwrap(String(data: JSONEncoder().encode(ChannelPrefs(favoritesFirst: false)), encoding: .utf8))
        XCTAssertEqual(body, #"{"favoritesFirst":false}"#)
    }

    func testLogoFallback() throws {
        let json = #"{"id":4,"number":104,"name":"Первый канал","logoUrl":"/a.png","logoAlt":"/b.png","logoAuto":true}"#
        let both = try JSONDecoder().decode(Channel.self, from: Data(json.utf8))
        XCTAssertEqual(both.logoCandidates, ["/a.png", "/b.png"], "logo, then the guide's icon")
        let altOnly = try JSONDecoder().decode(Channel.self, from: Data(#"{"id":5,"name":"X","logoAlt":"/b.png"}"#.utf8))
        XCTAssertEqual(altOnly.logoCandidates, ["/b.png"])
        XCTAssertEqual(Channel(id: 1, number: 1, name: "A", logoUrl: "/a", logoAlt: "/a").logoCandidates, ["/a"])
        XCTAssertTrue(Channel(id: 1, number: 1, name: "A").logoCandidates.isEmpty)
        // Neither: the initials.
        XCTAssertEqual(both.initials, "ПК")
        XCTAssertEqual(Channel(id: 1, number: 1, name: "cnn").initials, "CN")
        XCTAssertEqual(Channel(id: 1, number: 1, name: "Кино 2").initials, "К2")
        XCTAssertEqual(Channel(id: 1, number: 12, name: " · ").initials, "12")
        // The guide's rows carry logoAlt too, and take the list's when they came without.
        var grid = ChannelGuideGrid(ChannelEPGWindow(from: Date(), to: Date(), channels: [ChannelEPG(id: 4, number: 104, name: "Первый канал")]))
        grid.applyLogos(from: [both])
        XCTAssertEqual(grid.rows.first?.channel.logoCandidates, ["/a.png", "/b.png"])
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

    func testZappingWrapsInTheListsOrder() {
        // The list's order (the server's): channel up is the next row, not the next number.
        let channels = [channel(7, 100), channel(1, 1), channel(2, 10), channel(3, 11)]
        XCTAssertEqual(Channel.neighbour(of: 2, in: channels, step: 1)?.id, 3)
        XCTAssertEqual(Channel.neighbour(of: 2, in: channels, step: -1)?.id, 1)
        XCTAssertEqual(Channel.neighbour(of: 7, in: channels, step: 1)?.id, 1, "the row after 100 (listed first) is 1")
        XCTAssertEqual(Channel.neighbour(of: 3, in: channels, step: 1)?.id, 7, "channel up from the last row wraps to the first")
        XCTAssertEqual(Channel.neighbour(of: 7, in: channels, step: -1)?.id, 3, "channel down from the first row wraps to the last")
        XCTAssertEqual(Channel.neighbour(of: 1, in: channels, step: 5)?.id, 2)
        XCTAssertEqual(Channel.neighbour(of: 1, in: [channel(1, 1)], step: 1)?.id, 1)
        XCTAssertNil(Channel.neighbour(of: 99, in: channels, step: 1))
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

    func testGuideFavouritesAndLastChannelRequests() async throws {
        let transport = MockTransport { request in
            request.url?.path == "/api/channels/epg" ? .json(#"{"from":"2026-11-11T21:00:00Z","to":"2026-11-11T23:00:00Z","channels":[]}"#) : .noContent
        }
        let client = APIClient(baseURL: base, token: "t", transport: transport)
        let window = try await client.channelEPG(from: Date(timeIntervalSince1970: 1_700_000_000), hours: 30)
        XCTAssertEqual(window.to.timeIntervalSince(window.from), 2 * 3600)
        _ = try await client.channelEPG()
        try await client.setChannelFavorite(id: 3, true)
        try await client.setChannelFavorite(id: 3, false)
        try await client.setLastChannel(id: 5)
        let requests = transport.requests
        XCTAssertEqual(requests.map { "\($0.httpMethod ?? "") \($0.pathAndQuery)" }, [
            "GET /api/channels/epg?from=2023-11-14T22%3A13%3A20.000Z&hours=24",
            "GET /api/channels/epg?hours=6",
            "PUT /api/channels/3/favorite",
            "DELETE /api/channels/3/favorite",
            "PUT /api/channels/last",
        ])
        XCTAssertEqual(requests[4].bodyJSON?["channelId"] as? Int, 5)
        XCTAssertNil(requests[2].httpBody)
    }

    func testInterfaceLanguage() async throws {
        let transport = MockTransport { request in
            request.httpMethod == "PUT" ? .json(#"{"language":"en","effective":"en"}"#) : .json(#"{"language":"","effective":"ru"}"#)
        }
        let client = APIClient(baseURL: base, token: "t", transport: transport)
        let current = try await client.uiLanguage()
        XCTAssertEqual(current, UILanguage(language: "", effective: "ru"))
        let chosen = try await client.setUILanguage("en")
        XCTAssertEqual(chosen.effective, "en")
        XCTAssertEqual(transport.requests.map { "\($0.httpMethod ?? "") \($0.pathAndQuery)" }, ["GET /api/me/ui-language", "PUT /api/me/ui-language"])
        XCTAssertEqual(transport.requests[1].bodyJSON?["language"] as? String, "en")
        XCTAssertEqual(try JSONDecoder().decode(UILanguage.self, from: Data("{}".utf8)), UILanguage())
    }

    func testEveryRequestSaysItListsExternalAudio() async throws {
        let transport = MockTransport { _ in .json(#"{"channels":[]}"#) }
        let client = APIClient(baseURL: base, token: "t", transport: transport)
        _ = try await client.channels()
        XCTAssertEqual(transport.requests[0].value(forHTTPHeaderField: "X-Vault-Caps"), "external-audio")
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
