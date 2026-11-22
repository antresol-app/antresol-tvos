import Foundation
import XCTest
@testable import AntresolKit

/// What a page does with the ways that watch: which run is busy and for whom, which way «Play»
/// runs, the rows of its menu, and the qualities and the ref an addon's stream brings along.
final class WayChoiceTests: XCTestCase {
    private let show = WayTarget(kind: "series", tmdbId: 7, inLibrary: false)
    private let movie = WayTarget(kind: "movie", tmdbId: 7, inLibrary: false)

    private func way(_ id: String, icon: WayIcon = .play, role: WayRole = .watch, addon: String = "alpha") -> AddonWay {
        AddonWay(addonId: addon, way: AppWay(id: id, label: id.capitalized, icon: icon, role: role, episodes: true))
    }

    // MARK: A run under way

    func testOnlyTheSubjectOfTheRunIsBusy() {
        var gate = WayRunGate()
        let key = WayRunKey(wayId: "alpha/watch", target: show.episode(season: 1, episode: 2, inLibrary: false))
        XCTAssertTrue(gate.begin(key))
        XCTAssertTrue(gate.isBusy)

        let same = show.episode(season: 1, episode: 2, inLibrary: false)
        XCTAssertTrue(gate.isRunning("alpha/watch", for: same))
        XCTAssertTrue(gate.isRunning(for: same))
        // The library flag can change under a page without the run being another one.
        XCTAssertTrue(gate.isRunning("alpha/watch", for: show.episode(season: 1, episode: 2, inLibrary: true)))

        XCTAssertFalse(gate.isRunning("alpha/watch", for: show.episode(season: 1, episode: 3, inLibrary: false)), "another episode")
        XCTAssertFalse(gate.isRunning("alpha/watch", for: show.episode(season: 2, episode: 2, inLibrary: false)), "another season")
        XCTAssertFalse(gate.isRunning("alpha/watch", for: show), "the title's own button")
        XCTAssertFalse(gate.isRunning("alpha/watch", for: movie), "another kind with the same id")
        XCTAssertFalse(gate.isRunning("alpha/watch", for: WayTarget(kind: "series", tmdbId: 8, inLibrary: false)), "another title")
        XCTAssertFalse(gate.isRunning("beta/watch", for: same), "another way (an addon's way id may repeat)")
        XCTAssertFalse(gate.isRunning(for: show))
    }

    func testOneRunAtATime() {
        var gate = WayRunGate()
        let first = WayRunKey(wayId: "alpha/watch", target: show.episode(season: 1, episode: 1, inLibrary: false))
        let second = WayRunKey(wayId: "alpha/watch", target: show.episode(season: 1, episode: 2, inLibrary: false))
        XCTAssertTrue(gate.begin(first))
        XCTAssertFalse(gate.begin(second), "another run waits for the one under way")
        XCTAssertFalse(gate.begin(first))
        gate.end(second)
        XCTAssertTrue(gate.isBusy, "a run that never held the slot gives nothing back")
        gate.end(first)
        XCTAssertFalse(gate.isBusy)
        XCTAssertTrue(gate.begin(second))
    }

    // MARK: Which way «Play» runs

    func testPlayRunsTheFirstWayUntilOneIsChosen() throws {
        let menu = try XCTUnwrap(WayMenu(ways: [way("online", icon: .globe), way("stream")], remembered: nil))
        XCTAssertEqual(menu.defaultWay.way.id, "online")
        XCTAssertEqual(menu.rows.map(\.isDefault), [true, false])
        XCTAssertEqual(menu.rows.map(\.hint), [.startsRightAway, .playsWhileDownloading])
    }

    func testPlayRunsTheRememberedWayWhileItIsOffered() throws {
        let ways = [way("online", icon: .globe), way("stream")]
        let chosen = try XCTUnwrap(WayMenu(ways: ways, remembered: "alpha/stream"))
        XCTAssertEqual(chosen.defaultWay.id, "alpha/stream")
        XCTAssertEqual(chosen.rows.map(\.isDefault), [false, true], "the default is the ticked row")
        // A remembered way the addons no longer offer (or one that only keeps a copy) is no default.
        XCTAssertEqual(try XCTUnwrap(WayMenu(ways: ways, remembered: "alpha/gone")).defaultWay.id, "alpha/online")
        let keep = way("fetch", icon: .download, role: .keep)
        XCTAssertEqual(try XCTUnwrap(WayMenu(ways: ways + [keep], remembered: "alpha/fetch")).defaultWay.id, "alpha/online")
    }

    func testTheMenuHoldsWatchingWaysOnly() throws {
        let menu = try XCTUnwrap(WayMenu(ways: [way("fetch", icon: .download, role: .keep), way("online", icon: .globe)], remembered: nil))
        XCTAssertEqual(menu.rows.map(\.id), ["alpha/online"], "a way that keeps a copy has its own round button")
        XCTAssertNil(WayMenu(ways: [way("fetch", icon: .download, role: .keep)], remembered: nil))
        XCTAssertNil(WayMenu(ways: [], remembered: "alpha/online"))
    }

    func testTwoAddonsWithOneWayIdStayTwoRows() throws {
        let menu = try XCTUnwrap(WayMenu(ways: [way("watch", addon: "alpha"), way("watch", addon: "beta")], remembered: "beta/watch"))
        XCTAssertEqual(menu.rows.map(\.id), ["alpha/watch", "beta/watch"])
        XCTAssertEqual(menu.defaultWay.addonId, "beta")
    }

    func testHintsComeFromTheGlyphOnly() {
        XCTAssertEqual(way("a", icon: .globe).hint, .startsRightAway)
        XCTAssertEqual(way("a", icon: .play).hint, .playsWhileDownloading)
        XCTAssertNil(way("a", icon: .download).hint)
        XCTAssertNil(way("a", icon: .list).hint)
    }

    func testTheChoiceIsRememberedPerTitleAndProfile() throws {
        let suite = "antresol.tests.waydefaults.\(UUID().uuidString)"
        let store = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { store.removePersistentDomain(forName: suite) }
        let ways = [way("online", icon: .globe), way("stream")]
        let mine = WayDefaults(defaults: store, scope: "1")
        XCTAssertEqual(mine.menu(for: ways, target: show)?.defaultWay.id, "alpha/online")

        mine.remember("alpha/stream", for: show)
        XCTAssertEqual(mine.remembered(for: show), "alpha/stream")
        XCTAssertEqual(mine.menu(for: ways, target: show)?.defaultWay.id, "alpha/stream")
        // Per title, whichever episode it is asked for.
        XCTAssertEqual(mine.menu(for: ways, target: show.episode(season: 2, episode: 5, inLibrary: false))?.defaultWay.id, "alpha/stream")
        XCTAssertEqual(mine.menu(for: ways, target: movie)?.defaultWay.id, "alpha/online", "another kind with the same TMDB id")
        XCTAssertEqual(WayDefaults(defaults: store, scope: "2").menu(for: ways, target: show)?.defaultWay.id, "alpha/online", "another profile")
        XCTAssertEqual(WayDefaults(defaults: store, scope: "1").remembered(for: show), "alpha/stream", "kept across launches")

        mine.forget(for: show)
        XCTAssertNil(mine.remembered(for: show))
    }

    // MARK: What an addon's stream brings along

    private func play(_ extra: String) throws -> WayPlay {
        let json = #"{"play":{"url":"/api/addons/alpha/x/media/s1/a.mp4","session":"s1"\#(extra)}}"#
        guard case .play(let play) = try JSONDecoder().decode(WayRunResult.self, from: Data(json.utf8)) else {
            throw XCTSkip("not a play answer")
        }
        return play
    }

    func testTheAnswerGivesQualitiesAndTheRefToPlayOneWith() throws {
        let both = try play(#","quality":{"options":["720p","1080p"],"current":"1080p"},"ref":"abc""#)
        XCTAssertEqual(both.quality, StreamQuality(options: ["720p", "1080p"], current: "1080p"))
        XCTAssertEqual(both.ref, "abc")
        XCTAssertEqual(both.qualityChoice?.options, ["720p", "1080p"])
        XCTAssertTrue(try XCTUnwrap(both.quality).offers("720p"))
        XCTAssertFalse(try XCTUnwrap(both.quality).offers("480p"))

        // The core's own `quality` shape (selected/applied) is no list of options.
        let core = try play(#","quality":{"selected":"auto","applied":"original","remote":false}"#)
        XCTAssertNil(core.quality)
        XCTAssertNil(core.qualityChoice)
    }

    func testNoChoiceWithoutAWayToPlayAnother() throws {
        // One quality is no choice; two without a ref could not be played.
        XCTAssertNil(try play(#","quality":{"options":["720p"],"current":"720p"},"ref":"abc""#).qualityChoice)
        XCTAssertNil(try play(#","quality":{"options":["720p","1080p"],"current":"720p"}"#).qualityChoice)
        XCTAssertNil(try play(#","quality":{"options":["720p","1080p"],"current":"720p"},"ref":"""#).qualityChoice, "an empty ref plays nothing")
        XCTAssertNil(try play("").quality)
        XCTAssertNil(try play(#","quality":{"options":["",""],"current":""}"#).quality, "names that are all empty list nothing")
    }

    func testQualityAndRefAlsoComeBesideThePlay() throws {
        let json = #"{"play":{"url":"/api/addons/alpha/x/media/s1/a.mp4"},"session":"s1","quality":{"options":["a","b"],"current":"a"},"ref":"r9"}"#
        guard case .play(let play) = try JSONDecoder().decode(WayRunResult.self, from: Data(json.utf8)) else { return XCTFail("play") }
        XCTAssertEqual(play.qualityChoice?.current, "a")
        XCTAssertEqual(play.ref, "r9")
    }

    func testARunInAnotherQualityNamesItAndKeepsTheRef() throws {
        let target = WayTarget(kind: "movie", tmdbId: 603, inLibrary: false)
        let request = WayRunRequest(way: "go", target: target, ref: "abc", startSec: 321, refresh: true, quality: "720p")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
        XCTAssertEqual(json["quality"] as? String, "720p")
        XCTAssertEqual(json["ref"] as? String, "abc")
        XCTAssertEqual(json["startSec"] as? Double, 321)
        XCTAssertEqual(json["refresh"] as? Bool, true)
        XCTAssertNil(json["quick"])
        let plain = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(WayRunRequest(way: "go", target: target, quick: true))) as? [String: Any])
        XCTAssertNil(plain["quality"], "a first run leaves the quality to the addon")
        let empty = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(WayRunRequest(way: "go", target: target, quality: ""))) as? [String: Any])
        XCTAssertNil(empty["quality"])
    }
}
