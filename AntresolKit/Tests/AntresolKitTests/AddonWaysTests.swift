import Foundation
import XCTest
@testable import AntresolKit
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The `x/app` protocol of the server's addons: models, discovery and its cache, the calls,
/// the core's input player and the rules of where a way is offered.
final class AddonWaysTests: XCTestCase {
    private let base = URL(string: "http://tv.test:8420")!

    /// The request's JSON body is exactly `expected`.
    private func assertBody(_ request: URLRequest, _ expected: [String: Any], file: StaticString = #filePath, line: UInt = #line) {
        guard let body = request.bodyJSON else { return XCTFail("no JSON body", file: file, line: line) }
        XCTAssertTrue(NSDictionary(dictionary: body).isEqual(to: expected), "\(body) != \(expected)", file: file, line: line)
    }

    private func client(_ transport: MockTransport) -> APIClient {
        APIClient(baseURL: base, token: "t", language: "ru", transport: transport)
    }

    // MARK: Models

    func testAppInfoDecodesAndSkipsWhatItCannotShow() throws {
        let info = try Samples.decode(AppInfo.self, "addon-app-info.json")
        XCTAssertEqual(info.v, 1)
        XCTAssertEqual(info.ways.map(\.id), ["go", "fetch", "odd"], "an unknown role and a way without an id are left out")
        XCTAssertEqual(info.ways.map(\.icon), [.globe, .download, .play], "an unknown icon is a play icon")
        XCTAssertEqual(info.ways.map(\.role), [.watch, .keep, .watch])
        XCTAssertEqual(info.ways[0].label, "Watch here")
        XCTAssertEqual(info.ways[0].scope, .any)
        XCTAssertTrue(info.ways[0].episodes)
        XCTAssertFalse(info.ways[1].episodes)
        XCTAssertEqual(info.search?.label, "Find and watch")
    }

    func testAppInfoWithoutSearchAndWithAnotherVersion() throws {
        let plain = try JSONDecoder().decode(AppInfo.self, from: Data(#"{"v":1,"ways":[]}"#.utf8))
        XCTAssertNil(plain.search)
        XCTAssertEqual(plain.ways, [])
        let empty = try JSONDecoder().decode(AppInfo.self, from: Data(#"{"v":1,"ways":[],"search":{"label":" "}}"#.utf8))
        XCTAssertNil(empty.search, "a heading without words is no search")
        XCTAssertThrowsError(try JSONDecoder().decode(AppInfo.self, from: Data(#"{"v":2,"ways":[]}"#.utf8)), "another protocol version")
        XCTAssertThrowsError(try JSONDecoder().decode(AppInfo.self, from: Data(#"{"ways":[]}"#.utf8)), "no version")
    }

    func testWaysOfOneAddonKeepTheirFirstOfAnId() throws {
        let json = #"{"v":1,"ways":[{"id":"a","label":"One","role":"watch","kinds":["movie"]},{"id":"a","label":"Two","role":"keep","kinds":["movie"]}]}"#
        let info = try JSONDecoder().decode(AppInfo.self, from: Data(json.utf8))
        XCTAssertEqual(info.ways.map(\.label), ["One"])
    }

    func testWhereAWayIsOffered() {
        let any = AddonWay(addonId: "alpha", way: AppWay(id: "a", label: "A", kinds: ["movie", "series"], scope: .any, episodes: true))
        let outside = AddonWay(addonId: "alpha", way: AppWay(id: "b", label: "B", kinds: ["movie", "series"], scope: .outside, episodes: false))
        let inside = AddonWay(addonId: "beta", way: AppWay(id: "c", label: "C", kinds: ["series"], scope: .inside, episodes: true))
        let movieIn = WayTarget(kind: "movie", tmdbId: 1, inLibrary: true)
        let movieOut = WayTarget(kind: "movie", tmdbId: 1, inLibrary: false)
        let showIn = WayTarget(kind: "series", tmdbId: 2, inLibrary: true)
        let episodeIn = showIn.episode(season: 1, episode: 3, inLibrary: true)
        let episodeOut = showIn.episode(season: 1, episode: 4, inLibrary: false)

        XCTAssertEqual([any, outside, inside].filter { $0.isOffered(for: movieIn) }.map(\.way.id), ["a"])
        XCTAssertEqual([any, outside, inside].filter { $0.isOffered(for: movieOut) }.map(\.way.id), ["a", "b"])
        XCTAssertEqual([any, outside, inside].filter { $0.isOffered(for: showIn) }.map(\.way.id), ["a", "c"], "the kind is checked")
        XCTAssertEqual([any, outside, inside].filter { $0.isOffered(for: episodeIn) }.map(\.way.id), ["a", "c"], "an episode needs a way that takes one")
        XCTAssertEqual([any, outside, inside].filter { $0.isOffered(for: episodeOut) }.map(\.way.id), ["a"], "outside ways take only what the library lacks; b takes no episode")
    }

    func testAddonsMergeInTheOrderOfTheirIds() throws {
        func info(_ ways: [String], search: String? = nil) -> AppInfo {
            AppInfo(ways: ways.map { AppWay(id: $0, label: $0.uppercased()) }, search: search.map(AppSearch.init(label:)))
        }
        let snapshot = AddonCatalogSnapshot.merging([
            (addonId: "beta", info: info(["x", "y"], search: "Beta search")),
            (addonId: "alpha", info: info(["x"], search: "Alpha search")),
            (addonId: "beta", info: info(["z"])),
        ])
        XCTAssertEqual(snapshot.ways.map(\.id), ["alpha/x", "beta/x", "beta/y"], "by addon id; the same way id of two addons stays apart")
        XCTAssertEqual(snapshot.searches.map(\.label), ["Alpha search", "Beta search"])
        XCTAssertEqual(snapshot.way(id: "beta/y")?.label, "Y")
        XCTAssertTrue(AddonCatalogSnapshot.empty.isEmpty)
    }

    func testRolesSplitTheOfferedWays() {
        let snapshot = AddonCatalogSnapshot(ways: [
            AddonWay(addonId: "alpha", way: AppWay(id: "w", label: "W", role: .watch)),
            AddonWay(addonId: "alpha", way: AppWay(id: "k", label: "K", icon: .download, role: .keep)),
        ])
        let target = WayTarget(kind: "movie", tmdbId: 1, inLibrary: false)
        XCTAssertEqual(snapshot.ways(for: target).map(\.way.id), ["w", "k"])
        XCTAssertEqual(snapshot.ways(for: target, role: .watch).map(\.way.id), ["w"])
        XCTAssertEqual(snapshot.ways(for: target, role: .keep).map(\.way.id), ["k"])
    }

    func testAddonIdsArePlainWords() {
        for good in ["alpha", "beta-2", "a_b", "0f1e2d"] { XCTAssertTrue(AddonID.isValid(good), good) }
        for bad in ["", "a/b", "a b", "..", "a%2fb", "a;b", "a.b", String(repeating: "x", count: 65)] { XCTAssertFalse(AddonID.isValid(bad), bad) }
    }

    func testSearchTitles() throws {
        let titles = try Samples.decode(AddonTitleList.self, "addon-app-search.json").titles
        XCTAssertEqual(titles.map(\.id), ["movie-603", "series-1399"], "a kind the apps do not show and a repeated title are left out")
        XCTAssertEqual(titles[0].poster, "https://images.example.test/p/603.jpg")
        XCTAssertNil(titles[0].libraryId)
        XCTAssertEqual(titles[1].libraryId, 2)
        XCTAssertEqual(titles[1].year, 2011)
        let urls = ServerURLs(baseURL: base)
        XCTAssertEqual(urls.image(titles[0].poster)?.absoluteString, "https://images.example.test/p/603.jpg")
        XCTAssertEqual(urls.image(titles[1].poster)?.absoluteString, "http://tv.test:8420/api/images/local/2/poster")
        // `inLibrary` without an item id opens the card off the library.
        XCTAssertNil(AddonTitle(kind: "movie", tmdbId: 1, title: "T", inLibrary: true).libraryId)
    }

    func testStepRows() throws {
        let step = try Samples.decode(WayStep.self, "addon-step.json")
        XCTAssertEqual(step.title, "Source")
        XCTAssertEqual(step.note, "Pick one")
        XCTAssertEqual(step.empty, "Nothing found")
        XCTAssertEqual(step.rows.map(\.ref), ["r1", "r2"], "a repeated ref and a row without a ref are left out")
        XCTAssertEqual(step.rows[0].detail, "Second line")
        XCTAssertEqual(step.rows[0].badges, ["4K", "HDR"])
        XCTAssertTrue(step.rows[0].current)
        XCTAssertFalse(step.rows[0].isFinal)
        XCTAssertTrue(step.rows[1].isFinal)
        XCTAssertFalse(step.rows[1].current)
        let bare = try JSONDecoder().decode(WayStep.self, from: Data("{}".utf8))
        XCTAssertEqual(bare.rows, [])
        XCTAssertNil(bare.note)
    }

    func testRunResults() throws {
        XCTAssertEqual(try Samples.decode(WayRunResult.self, "addon-run-input.json"), .input("0f1e2d3c4b5a69788796a5b4c3d2e1f0"))
        XCTAssertEqual(try JSONDecoder().decode(WayRunResult.self, from: Data(#"{"done":"Started"}"#.utf8)), .done("Started"))
        XCTAssertEqual(try JSONDecoder().decode(WayRunResult.self, from: Data(#"{"pick":true}"#.utf8)), .pick)
        XCTAssertThrowsError(try JSONDecoder().decode(WayRunResult.self, from: Data(#"{"pick":false}"#.utf8)))
        XCTAssertThrowsError(try JSONDecoder().decode(WayRunResult.self, from: Data("{}".utf8)))
        XCTAssertThrowsError(try JSONDecoder().decode(WayRunResult.self, from: Data(#"{"input":""}"#.utf8)), "an empty id plays nothing")

        guard case .play(let play) = try Samples.decode(WayRunResult.self, "addon-run-play.json") else { return XCTFail("play") }
        XCTAssertEqual(play.response.url, "/api/addons/alpha/x/media/s1/index.m3u8")
        XCTAssertEqual(play.response.startSec, 12.5)
        XCTAssertEqual(play.response.subtitles.map(\.index), [0])
        XCTAssertEqual(play.response.subtitles.first?.url, "/api/addons/alpha/x/media/s1/subs/0.vtt")
        XCTAssertFalse(play.response.mode.isHLS, "the addon's own stream is not one of the core's HLS sessions")
        XCTAssertEqual(play.session, "s1")
        XCTAssertEqual(play.progress, WayProgressSpec(path: "x/app/progress", every: 10))
        XCTAssertEqual(play.quality, StreamQuality(options: ["720", "1080"], current: "1080"))
        XCTAssertNil(play.qualityChoice, "the sample gives no ref to play another quality with")
    }

    func testPlayKeepsSessionAndProgressBesideItToo() throws {
        let json = #"{"play":{"url":"/api/addons/alpha/x/media/s2/a.mp4"},"session":"s2","progress":{"path":"x/app/progress","every":15}}"#
        guard case .play(let play) = try JSONDecoder().decode(WayRunResult.self, from: Data(json.utf8)) else { return XCTFail("play") }
        XCTAssertEqual(play.session, "s2")
        XCTAssertEqual(play.progress.every, 15)
        let bare = #"{"play":{"url":"/api/addons/alpha/x/media/s3/a.mp4"}}"#
        guard case .play(let plain) = try JSONDecoder().decode(WayRunResult.self, from: Data(bare.utf8)) else { return XCTFail("play") }
        XCTAssertNil(plain.session)
        XCTAssertEqual(plain.progress, WayProgressSpec(), "the protocol's own path and period")
    }

    func testProgressPathStaysUnderTheProtocol() {
        for path in ["../x", "x/other/progress", "x/app/../../progress", "/api/progress/1", "x/app/p?x=1"] {
            let spec = WayProgressSpec(raw: .init(path: path, every: 10))
            XCTAssertEqual(spec.path, "x/app/progress", path)
        }
        XCTAssertEqual(WayProgressSpec(raw: .init(path: "x/app/progress", every: 0.1)).every, 2)
        XCTAssertEqual(WayProgressSpec(raw: .init(path: nil, every: 9999)).every, 60)
    }

    func testStateDecodesAndPollsWhileActive() throws {
        let states = try Samples.decode(WayStates.self, "addon-state.json").ways
        XCTAssertEqual(states["fetch"], WayState(active: true, fraction: 0.4, text: "Fetched 40%", cancel: true))
        XCTAssertEqual(states["go"], WayState(active: false))
        XCTAssertTrue(WayStatePolling.shouldContinue(states))
        XCTAssertFalse(WayStatePolling.shouldContinue(["go": WayState()]))
        XCTAssertFalse(WayStatePolling.shouldContinue([:]))
        XCTAssertEqual(WayStatePolling.interval, 5)
        let clamped = try JSONDecoder().decode(WayState.self, from: Data(#"{"active":true,"fraction":4}"#.utf8))
        XCTAssertEqual(clamped.fraction, 1)
        XCTAssertFalse(clamped.cancel)
    }

    func testTitleInfo() throws {
        let info = try Samples.decode(TitleInfo.self, "title-info.json")
        XCTAssertEqual(info.tmdbId, 1399)
        XCTAssertEqual(info.kind, "series")
        XCTAssertEqual(info.target, WayTarget(kind: "series", tmdbId: 1399, inLibrary: false))
        XCTAssertEqual(info.seasons.map(\.number), [1, 2])
        XCTAssertEqual(info.cast.first?.name, "Ada Example")
        XCTAssertNil(info.libraryItemId)
    }

    // MARK: Calls

    func testDiscoveryIsReadFromTheOpenAddonsOnly() async throws {
        let transport = MockTransport { _ in
            .json(#"[{"id":"beta","entry":"/x/beta.js","style":"/x/b.css"},{"id":"alpha","entry":"/x/a.js"},{"id":"../etc","entry":"/x"},{"entry":"/none"}]"#)
        }
        let ids = try await client(transport).openAddonIds()
        XCTAssertEqual(ids, ["beta", "alpha"], "an id that is not a plain word is dropped")
        XCTAssertEqual(transport.requests.first?.pathAndQuery, "/api/addons/web")
        XCTAssertEqual(transport.requests.first?.value(forHTTPHeaderField: "Authorization"), "Bearer t")
        XCTAssertEqual(transport.requests.first?.value(forHTTPHeaderField: "Accept-Language"), "ru")
    }

    func testCallsGoUnderTheAddonsProxy() async throws {
        let transport = MockTransport { request in
            switch request.pathAndQuery {
            case let path where path.hasSuffix("/x/app/step"):
                return .json(#"{"title":"T","rows":[]}"#)
            case let path where path.hasSuffix("/x/app/run"):
                return .json(#"{"done":"OK"}"#)
            case let path where path.contains("/x/app/state"):
                return .json(#"{"ways":{}}"#)
            case let path where path.hasSuffix("/x/app/cancel"):
                return .json(#"{"done":"Stopped"}"#)
            case let path where path.contains("/x/app/search"):
                return .json(#"{"titles":[]}"#)
            case let path where path.hasSuffix("/x/app"):
                return .json(#"{"v":1,"ways":[]}"#)
            default:
                return .noContent
            }
        }
        let api = client(transport)
        let target = WayTarget(kind: "series", tmdbId: 1399, season: 2, episode: 5, inLibrary: false)

        _ = try await api.appInfo(addon: "alpha")
        _ = try await api.addonTitles(addon: "alpha", query: "R&B a+b")
        _ = try await api.wayStep(addon: "alpha", WayStepRequest(way: "go", target: target, ref: "r1"))
        _ = try await api.wayRun(addon: "alpha", WayRunRequest(way: "go", target: target, ref: "r2", maxHeight: 2160, quick: true))
        _ = try await api.wayStates(addon: "alpha", target: WayTarget(kind: "movie", tmdbId: 603, inLibrary: false))
        let notice = try await api.wayCancel(addon: "alpha", WayCancelRequest(way: "fetch", target: WayTarget(kind: "series", tmdbId: 1399, inLibrary: false)))
        XCTAssertEqual(notice, "Stopped")

        let paths = transport.requests.map { "\($0.httpMethod ?? "") \($0.pathAndQuery)" }
        XCTAssertEqual(paths, [
            "GET /api/addons/alpha/x/app",
            "GET /api/addons/alpha/x/app/search?q=R%26B%20a%2Bb",
            "POST /api/addons/alpha/x/app/step",
            "POST /api/addons/alpha/x/app/run",
            "GET /api/addons/alpha/x/app/state?kind=movie&tmdbId=603",
            "POST /api/addons/alpha/x/app/cancel",
        ])

        assertBody(transport.requests[2], ["way": "go", "kind": "series", "tmdbId": 1399, "season": 2, "episode": 5, "ref": "r1"])
        let run = try XCTUnwrap(transport.requests[3].bodyJSON)
        XCTAssertEqual(run["way"] as? String, "go")
        XCTAssertEqual(run["ref"] as? String, "r2")
        XCTAssertEqual(run["maxHeight"] as? Int, 2160)
        XCTAssertEqual(run["quick"] as? Bool, true)
        XCTAssertNil(run["refresh"], "left out unless asked for")
        XCTAssertNil(run["startSec"])
        assertBody(transport.requests[5], ["way": "fetch", "kind": "series", "tmdbId": 1399])
        XCTAssertGreaterThanOrEqual(transport.requests[2].timeoutInterval, 30, "a step can look for sources for most of half a minute")
        XCTAssertGreaterThan(transport.requests[3].timeoutInterval, transport.requests[2].timeoutInterval)
        XCTAssertEqual(transport.requests[2].value(forHTTPHeaderField: "Content-Type"), "application/json")
    }

    func testRefreshRunKeepsTheSameChoice() throws {
        let target = WayTarget(kind: "movie", tmdbId: 603, inLibrary: false)
        let request = WayRunRequest(way: "go", target: target, ref: "r2", startSec: 42, refresh: true)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
        XCTAssertEqual(json["refresh"] as? Bool, true)
        XCTAssertEqual(json["ref"] as? String, "r2")
        XCTAssertEqual(json["startSec"] as? Double, 42)
        XCTAssertNil(json["quick"])
        // 0 is a start from the beginning, not "none": the addon would pick up its saved position.
        let fromStart = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(WayRunRequest(way: "go", target: target, startSec: 0, refresh: true))) as? [String: Any])
        XCTAssertEqual(fromStart["startSec"] as? Double, 0)
        let plain = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(WayRunRequest(way: "go", target: target, quick: true))) as? [String: Any])
        XCTAssertNil(plain["startSec"], "a first run leaves the start to the addon")
    }

    func testStateAskedForASeasonOnlyWhenTargetHasOne() async throws {
        let transport = MockTransport { _ in .json(#"{"ways":{"fetch":{"active":true,"fraction":0.5}}}"#) }
        let states = try await client(transport).wayStates(addon: "alpha", target: WayTarget(kind: "series", tmdbId: 9, season: 3, inLibrary: false))
        XCTAssertEqual(transport.requests.first?.pathAndQuery, "/api/addons/alpha/x/app/state?kind=series&tmdbId=9&season=3")
        XCTAssertEqual(states["fetch"]?.fraction, 0.5)
    }

    func testProgressAndStopOfADirectlyPlayedWay() async throws {
        let transport = MockTransport { _ in .noContent }
        let api = client(transport)
        let target = WayTarget(kind: "series", tmdbId: 1399, season: 1, episode: 2, inLibrary: false)
        try await api.wayProgress(addon: "alpha", WayProgressUpdate(session: "s1", way: "go", target: target, positionMs: 61_000, durationMs: 120_000))
        try await api.wayProgress(addon: "alpha", path: "x/app/progress", WayProgressUpdate(session: "s1", way: "go", target: target, positionMs: 120_000, durationMs: 120_000, finished: true))
        try await api.wayStopPlay(addon: "alpha", session: "s 1/../x")
        let requests = transport.requests
        XCTAssertEqual(requests[0].httpMethod, "PUT")
        XCTAssertEqual(requests[0].pathAndQuery, "/api/addons/alpha/x/app/progress")
        assertBody(requests[0], ["session": "s1", "way": "go", "kind": "series", "tmdbId": 1399, "season": 1, "episode": 2, "positionMs": 61000, "durationMs": 120000])
        XCTAssertEqual(requests[1].bodyJSON?["finished"] as? Bool, true)
        XCTAssertEqual(requests[2].httpMethod, "DELETE")
        XCTAssertEqual(requests[2].pathAndQuery, "/api/addons/alpha/x/app/play/s%201%2F..%2Fx", "a session id never makes a path of its own")
    }

    func testAnAddonIdThatIsNotAWordIsNeverCalled() async {
        let transport = MockTransport { _ in .json("{}") }
        let api = client(transport)
        for id in ["../x", "a/b", ""] {
            do {
                _ = try await api.appInfo(addon: id)
                XCTFail("\(id) must be refused")
            } catch {}
        }
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testTitleOffTheLibrary() async throws {
        let transport = MockTransport { _ in .json(try! String(decoding: Samples.data("title-info.json"), as: UTF8.self)) }
        let info = try await client(transport).titleInfo(kind: "series", tmdbId: 1399)
        XCTAssertEqual(transport.requests.first?.pathAndQuery, "/api/title/series/1399")
        XCTAssertEqual(info.title, "Sample Show")
        do {
            _ = try await client(transport).titleInfo(kind: "music", tmdbId: 1)
            XCTFail("only a movie or a series has a title page")
        } catch {}
        XCTAssertEqual(transport.requests.count, 1)
    }

    // MARK: Discovery cache

    private func discoveryTransport(addons: String = #"[{"id":"beta","entry":"/b.js"},{"id":"alpha","entry":"/a.js"},{"id":"gamma","entry":"/g.js"}]"#) -> MockTransport {
        MockTransport { request in
            let path = request.pathAndQuery
            switch path {
            case "/api/addons/web": return .json(addons)
            case "/api/addons/alpha/x/app": return .json(#"{"v":1,"ways":[{"id":"a1","label":"A1","role":"watch","kinds":["movie"]}],"search":{"label":"Alpha"}}"#)
            case "/api/addons/beta/x/app": return .json(#"{"v":1,"ways":[{"id":"b1","label":"B1","role":"keep","kinds":["movie"]}]}"#)
            case "/api/addons/gamma/x/app": return .json(#"{"error":"not here"}"#, status: 404)
            default: return .json("{}", status: 404)
            }
        }
    }

    func testCatalogFindsWaysOnceAndKeepsThem() async {
        let transport = discoveryTransport()
        let catalog = AddonCatalog(client: client(transport))
        let first = await catalog.snapshot()
        let second = await catalog.snapshot()
        XCTAssertEqual(first.ways.map(\.id), ["alpha/a1", "beta/b1"], "an addon without the protocol (404) offers nothing")
        XCTAssertEqual(first.searches.map(\.label), ["Alpha"])
        XCTAssertEqual(first, second)
        XCTAssertEqual(transport.requests.count, 4, "one list and three addons, asked once for the session")
    }

    func testCatalogLooksAgainAfterInvalidate() async {
        let transport = discoveryTransport()
        let catalog = AddonCatalog(client: client(transport))
        _ = await catalog.snapshot()
        await catalog.invalidate()
        _ = await catalog.snapshot()
        XCTAssertEqual(transport.requests.count, 8)
    }

    func testNoAddonsIsSilentAndKept() async {
        for status in [403, 404] {
            let transport = MockTransport { _ in .json(#"{"error":"no"}"#, status: status) }
            let catalog = AddonCatalog(client: client(transport))
            let first = await catalog.snapshot()
            _ = await catalog.snapshot()
            XCTAssertTrue(first.isEmpty, "\(status)")
            XCTAssertEqual(transport.requests.count, 1, "a definite refusal is not asked again")
        }
    }

    func testAnUnreadableAddonOrAnotherVersionOffersNothing() async {
        let transport = MockTransport { request in
            switch request.pathAndQuery {
            case "/api/addons/web": return .json(#"[{"id":"alpha","entry":"/a"},{"id":"beta","entry":"/b"},{"id":"gamma","entry":"/g"}]"#)
            case "/api/addons/alpha/x/app": return .json("not json")
            case "/api/addons/beta/x/app": return .json(#"{"v":7,"ways":[{"id":"x","label":"X","role":"watch","kinds":["movie"]}]}"#)
            default: return .json(#"{"v":1,"ways":[{"id":"g","label":"G","role":"watch","kinds":["movie"]}]}"#)
            }
        }
        let snapshot = await AddonCatalog(client: client(transport)).snapshot()
        XCTAssertEqual(snapshot.ways.map(\.id), ["gamma/g"])
    }

    func testABusyServerIsAskedAgainSoonButNotAtOnce() async {
        let clock = Locked(Date(timeIntervalSince1970: 1_000))
        let failing = Locked(true)
        let transport = MockTransport { request in
            if request.pathAndQuery == "/api/addons/web" { return .json(#"[{"id":"alpha","entry":"/a"}]"#) }
            return failing.current
                ? .json(#"{"error":"starting"}"#, status: 503)
                : .json(#"{"v":1,"ways":[{"id":"a1","label":"A1","role":"watch","kinds":["movie"]}]}"#)
        }
        let catalog = AddonCatalog(client: client(transport), now: { clock.current })
        let first = await catalog.snapshot()
        XCTAssertTrue(first.isEmpty)
        failing.withLock { $0 = false }
        let soon = await catalog.snapshot()
        XCTAssertTrue(soon.isEmpty, "not asked again within the minute")
        XCTAssertEqual(transport.requests.count, 2)
        clock.withLock { $0 = $0.addingTimeInterval(AddonCatalog.incompleteRetry + 1) }
        let later = await catalog.snapshot()
        XCTAssertEqual(later.ways.map(\.id), ["alpha/a1"])
    }

    func testAnUnreachableServerIsRetried() async {
        let transport = MockTransport { _ in .json("x", status: 502) }
        let catalog = AddonCatalog(client: client(transport), now: { Date(timeIntervalSince1970: 1) })
        _ = await catalog.snapshot()
        _ = await catalog.snapshot()
        XCTAssertEqual(transport.requests.count, 1, "kept for a minute")
    }

    // MARK: The core's input player

    func testInputInfo() async throws {
        let json = #"{"id":"ab12","addonId":"alpha","name":"Clip","itemId":7,"title":{"kind":"movie","tmdbId":603,"season":0,"episode":0},"slow":true,"meta":{"k":1},"startSec":91.5}"#
        let transport = MockTransport { _ in .json(json) }
        let info = try await client(transport).inputInfo(id: "ab12")
        XCTAssertEqual(transport.requests.first?.pathAndQuery, "/api/play/input/ab12")
        XCTAssertEqual(info, InputInfo(id: "ab12", name: "Clip", itemId: 7, slow: true, startSec: 91.5))
    }

    func testInputPlayIsAskedAgainWhilePending() async throws {
        let calls = Locked(0)
        let transport = MockTransport { _ in
            let n = calls.withLock { value -> Int in value += 1; return value }
            return n < 4 ? .json(#"{"pending":true}"#, status: 202) : .json(#"{"mode":"direct","url":"/api/play/input/ab12/direct","startSec":0,"durationMs":60000,"audioIndex":-1,"audio":[],"subtitles":[],"quality":{"selected":"auto","applied":"original","remote":false}}"#)
        }
        let slept = Locked<[Double]>([])
        let request = PlayRequest(caps: .appleTV(), startSec: 0)
        let response = try await client(transport).startInputPlay(id: "ab12", request) { seconds in slept.withLock { $0.append(seconds) } }
        XCTAssertEqual(response.url, "/api/play/input/ab12/direct")
        XCTAssertEqual(response.mode, .direct)
        XCTAssertEqual(slept.current, [1.5, 1.5, 1.5], "every 1.5 s")
        XCTAssertEqual(transport.requests.count, 4)
        let first = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(first.httpMethod, "POST")
        XCTAssertEqual(first.pathAndQuery, "/api/play/input/ab12")
        XCTAssertNotNil(first.bodyJSON?["caps"], "the body is /api/play's: the device's capabilities")
    }

    func testInputPlayGivesUpAfterAboutNinetySeconds() async {
        let transport = MockTransport { _ in .json(#"{"pending":true}"#, status: 202) }
        let slept = Locked<[Double]>([])
        do {
            _ = try await client(transport).startInputPlay(id: "ab12", PlayRequest(caps: .appleTV())) { seconds in slept.withLock { $0.append(seconds) } }
            XCTFail("expected an error")
        } catch let error as APIError {
            XCTAssertEqual(error.statusCode, 504)
        } catch {
            XCTFail("\(error)")
        }
        XCTAssertEqual(slept.current.reduce(0, +), 90, accuracy: 0.001)
    }

    func testInputPlayAnswersAreNotRetried() async {
        for status in [404, 502] {
            let transport = MockTransport { _ in .json(#"{"error":"Not readable"}"#, status: status) }
            do {
                _ = try await client(transport).startInputPlay(id: "ab12", PlayRequest(caps: .appleTV())) { _ in XCTFail("no wait") }
                XCTFail("expected an error")
            } catch let error as APIError {
                XCTAssertEqual(error.statusCode, status)
                XCTAssertEqual(error.serverMessage, "Not readable")
            } catch {
                XCTFail("\(error)")
            }
            XCTAssertEqual(transport.requests.count, 1)
        }
    }

    func testInputProgress() async throws {
        let transport = MockTransport { _ in .noContent }
        let api = client(transport)
        try await api.updateInputProgress(id: "ab12", positionMs: 5000, durationMs: 60000, keepalive: false)
        try await api.updateInputProgress(id: "ab12", positionMs: 60000, durationMs: 60000, keepalive: true)
        XCTAssertEqual(transport.requests[0].httpMethod, "PUT")
        XCTAssertEqual(transport.requests[0].pathAndQuery, "/api/play/input/ab12/progress")
        assertBody(transport.requests[0], ["positionMs": 5000, "durationMs": 60000, "keepalive": false])
        XCTAssertEqual(transport.requests[1].bodyJSON?["keepalive"] as? Bool, true)
    }

    func testAnInputSessionAsksThroughItsRequester() async throws {
        let transport = MockTransport { request in
            request.pathAndQuery == "/api/auth/media-key" ? .json(#"{"key":"mk1","expiresAt":"2099-01-01T00:00:00Z"}"#) : .noContent
        }
        let api = client(transport)
        let asked = Locked<[Double?]>([])
        let session = VideoPlaybackSession(client: api, mediaKeys: MediaKeyStore(client: api)) { request in
            asked.withLock { $0.append(request.startSec) }
            return try JSONDecoder().decode(PlayResponse.self, from: Data(#"{"mode":"direct","url":"/api/play/input/ab12/direct","durationMs":60000}"#.utf8))
        }
        let source = try await session.start(at: 30)
        XCTAssertEqual(source.url.absoluteString, "http://tv.test:8420/api/play/input/ab12/direct?mk=mk1")
        XCTAssertEqual(source.initialPlayerSeek, 30)
        XCTAssertEqual(asked.current, [0], "the whole stream is asked for and the player seeks")
        XCTAssertFalse(transport.requests.contains { $0.pathAndQuery.hasPrefix("/api/play/0") }, "never a library file's /api/play")
    }

    func testProgressGoesToTheSenderOfAnAddonStream() async {
        let sent = Locked<[String]>([])
        let reporter = PlaybackProgressReporter(interval: 1000) { position, duration, keepalive in
            sent.withLock { $0.append("\(position)/\(duration)/\(keepalive)") }
        }
        await reporter.update(positionMs: 5_000, durationMs: 60_000)
        await reporter.reportIfMoved()
        await reporter.update(positionMs: 5_100, durationMs: 60_000)
        await reporter.reportIfMoved()
        await reporter.update(positionMs: 9_000, durationMs: 60_000)
        await reporter.stop()
        XCTAssertEqual(sent.current, ["5000/60000/false", "9000/60000/true"], "a small move waits; the last write must not be held back")
    }

    // MARK: Trailers

    func testAPageOffersTheBestThreeTrailers() {
        XCTAssertEqual(TrailerList.maxOffered, 3)
    }
}
