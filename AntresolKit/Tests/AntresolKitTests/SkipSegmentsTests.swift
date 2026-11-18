import Foundation
import XCTest
@testable import AntresolKit
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class SkipSegmentsTests: XCTestCase {
    private let recap = PlaySegment(kind: "recap", startSec: 0, endSec: 40)
    private let intro = PlaySegment(kind: "intro", startSec: 60, endSec: 150)
    private let credits = PlaySegment(kind: "credits", startSec: 2500, endSec: 2590)
    private var episode: [PlaySegment] { [credits, intro, recap] }

    func testPlayAnswerCarriesTheSegments() throws {
        let play = try JSONDecoder().decode(PlayResponse.self, from: Data(
            #"{"mode":"direct","url":"/api/stream/1","segments":[{"kind":"intro","startSec":60,"endSec":150.5}]}"#.utf8
        ))
        XCTAssertEqual(play.segments, [PlaySegment(kind: "intro", startSec: 60, endSec: 150.5)])
        // an older server sends none
        let old = try JSONDecoder().decode(PlayResponse.self, from: Data(#"{"mode":"direct","url":"/x"}"#.utf8))
        XCTAssertTrue(old.segments.isEmpty)
    }

    func testAutoSkipIsReadAndSavedPartially() async throws {
        let transport = MockTransport { request in
            request.httpMethod == "PUT"
                ? .json(#"{"audioLangs":["ru"],"subMode":"off","subLangs":["ru"],"autoSkip":{"recap":false,"intro":true,"credits":false}}"#)
                : .json(#"{"audioLangs":["ru"],"subMode":"off","subLangs":["ru"]}"#)
        }
        let client = APIClient(baseURL: URL(string: "http://tv.test:8420")!, token: "t", transport: transport)
        // an older server has no autoSkip: all off
        let old = try await client.playbackPrefs()
        XCTAssertEqual(old.autoSkip, AutoSkip())

        let saved = try await client.setAutoSkip("intro", true)
        let put = transport.requests[1]
        XCTAssertEqual(put.httpMethod, "PUT")
        XCTAssertEqual(put.pathAndQuery, "/api/me/playback-prefs/auto-skip")
        // only the kind that changed: the others stay on the server
        XCTAssertEqual(put.bodyJSON?.count, 1)
        XCTAssertEqual(put.bodyJSON?["intro"] as? Bool, true)
        XCTAssertEqual(saved.autoSkip, AutoSkip(recap: false, intro: true, credits: false))
    }

    func testUsableDropsShortAndUnknownSegmentsAndSorts() {
        let segs = SkipSegments.usable(episode + [
            PlaySegment(kind: "intro", startSec: 200, endSec: 202.9),
            PlaySegment(kind: "preview", startSec: 300, endSec: 400),
            PlaySegment(kind: "recap", startSec: 500, endSec: .nan),
        ])
        XCTAssertEqual(segs, [recap, intro, credits])
        // 3 s exactly is offered
        XCTAssertEqual(SkipSegments.usable([PlaySegment(kind: "intro", startSec: 10, endSec: 13)]).count, 1)
    }

    func testSegmentAtCountsTheLastQuarterSecondAsOut() {
        let segs = SkipSegments.usable(episode)
        XCTAssertEqual(SkipSegments.at(segs, time: 60), intro)
        XCTAssertEqual(SkipSegments.at(segs, time: 149.7), intro)
        XCTAssertNil(SkipSegments.at(segs, time: 149.8)) // a seek to its end lands here
        XCTAssertNil(SkipSegments.at(segs, time: 59.9))
        XCTAssertNil(SkipSegments.at(segs, time: 45))
    }

    func testPostCreditsSceneAndCreditsToEnd() {
        XCTAssertTrue(SkipSegments.postCreditsScene(credits, durationSec: 2620)) // 30 s after the credits
        XCTAssertFalse(SkipSegments.postCreditsScene(credits, durationSec: 2605)) // 15 s: not a scene
        XCTAssertFalse(SkipSegments.postCreditsScene(credits, durationSec: 0)) // unknown duration
        XCTAssertTrue(SkipSegments.creditsToEnd(credits, durationSec: 2590.5))
        XCTAssertFalse(SkipSegments.creditsToEnd(credits, durationSec: 2600))
        XCTAssertTrue(SkipSegments.creditsToEnd(credits, durationSec: 0))
        XCTAssertEqual(SkipSegments.countdown(playedSec: 5), 0.5, accuracy: 1e-9)
        XCTAssertEqual(SkipSegments.countdown(playedSec: 100), 1, accuracy: 1e-9)
        XCTAssertEqual(SkipSegments.countdown(playedSec: -3), 0, accuracy: 1e-9)
    }

    func testTheNextPillWaitsForTheSystemPanelAtTheCreditsStartOnly() {
        // playback has just reached the credits and a proposal waits: the panel comes
        XCTAssertTrue(SkipSegments.upNextPanelPending(position: 2500.3, creditsStartSec: 2500, proposalAttached: true))
        // no proposal (not attached yet, or declined): the pill is the offer
        XCTAssertFalse(SkipSegments.upNextPanelPending(position: 2500.3, creditsStartSec: 2500, proposalAttached: false))
        // credits entered by a resume or a seek: the panel's time is long gone
        XCTAssertFalse(SkipSegments.upNextPanelPending(position: 2540, creditsStartSec: 2500, proposalAttached: true))
        XCTAssertFalse(SkipSegments.upNextPanelPending(position: 2501.5, creditsStartSec: 2500, proposalAttached: true))
    }

    func testAResetTrackerOffersNothingAtTheCredits() {
        // what the player swaps in while it goes on to the next episode: the old file's
        // credits must not show «Skip Credits» (it would end the player) or run an auto-skip
        var reset = SkipTracker(segments: [])
        XCTAssertFalse(reset.hasSegments)
        let step = reset.at(2500, hasNext: false, auto: AutoSkip(recap: true, intro: true, credits: true))
        XCTAssertNil(step.pill)
        XCTAssertNil(step.auto)
    }

    func testIntroPillShowsAloneForEightSecondsThenOnlyWithTheControls() {
        var t = SkipTracker(segments: episode)
        XCTAssertNil(t.at(50).pill)
        let first = t.at(61, now: 1)
        XCTAssertEqual(first.pill, .skip(kind: "intro", alone: true, action: .seek(toSec: 150)))
        XCTAssertEqual(t.at(68, now: 8.999).pill?.isShown(controlsVisible: false), true)
        let late = t.at(69, now: 9)
        XCTAssertEqual(late.pill, .skip(kind: "intro", alone: false, action: .seek(toSec: 150)))
        XCTAssertEqual(late.pill?.isShown(controlsVisible: false), false)
        XCTAssertEqual(late.pill?.isShown(controlsVisible: true), true)
        // leaving and entering again starts the 8 s afresh
        _ = t.at(40, now: 10)
        XCTAssertEqual(t.at(61, now: 20).pill?.isShown(controlsVisible: false), true)
    }

    func testAutoSkipSeeksPastARecapOnceWithANote() {
        var t = SkipTracker(segments: episode)
        let auto = AutoSkip(recap: true)
        // paused: nothing by itself
        XCTAssertNil(t.at(1, playing: false, auto: auto).auto)
        let step = t.at(1.5, auto: auto)
        XCTAssertEqual(step.auto, .skipped(toSec: 40, note: SkipNote(kind: "recap", backSec: 0)))
        XCTAssertNil(step.pill)
        // «Вернуть» seeks back into it: it is not skipped again, the pill is offered instead
        let back = t.at(0.5, auto: auto)
        XCTAssertNil(back.auto)
        if case .skip(let kind, _, _) = back.pill { XCTAssertEqual(kind, "recap") } else { XCTFail("no recap pill") }
        // the intro is not skipped with only the recap on
        XCTAssertNil(t.at(70, auto: auto).auto)
    }

    func testCreditsOfAnEpisodeOfferNextAndCountDown() {
        var t = SkipTracker(segments: episode)
        // a tick a second, playing: ten seconds of it fill the pill
        XCTAssertEqual(t.at(2500, now: 0).pill, .next(fill: 0, countdown: true))
        for s in 1..<5 { _ = t.at(2500 + Double(s), now: Double(s)) }
        XCTAssertEqual(t.at(2505, now: 5).pill, .next(fill: 0.5, countdown: true))
        for s in 6..<10 { XCTAssertNil(t.at(2500 + Double(s), now: Double(s)).auto) }
        XCTAssertEqual(t.at(2510, now: 10).auto, .next)
        // only once
        XCTAssertNil(t.at(2511, now: 11).auto)
        XCTAssertFalse(t.takeNext())
    }

    func testSeekingForwardInTheCreditsDoesNotSkipTheCountdown() {
        var t = SkipTracker(segments: episode)
        _ = t.at(2500, now: 0)
        _ = t.at(2501, now: 1)
        // +30 s, then the position moves on: the fill follows the playing time, not the file's
        let after = t.at(2580, now: 1.5)
        XCTAssertEqual(after.pill, .next(fill: 0.15, countdown: true))
        XCTAssertNil(after.auto)
        XCTAssertEqual(t.at(2581, now: 2).pill, .next(fill: 0.2, countdown: true))
        // a jump back into the credits keeps counting too
        XCTAssertEqual(t.at(2510, now: 2.5).pill, .next(fill: 0.25, countdown: true))
    }

    func testCountdownCountsOnlyPlayingTime() {
        var t = SkipTracker(segments: episode)
        _ = t.at(2500, now: 0)
        // paused for half a minute: nothing fills, and resuming does not add the pause
        XCTAssertEqual(t.at(2500, now: 5, playing: false).pill, .next(fill: 0, countdown: true))
        XCTAssertEqual(t.at(2500, now: 30, playing: false).pill, .next(fill: 0, countdown: true))
        XCTAssertEqual(t.at(2500.25, now: 30.25).pill, .next(fill: 0, countdown: true))
        XCTAssertEqual(t.at(2500.75, now: 30.75).pill, .next(fill: 0.05, countdown: true))
        // a stall (no tick for 30 s while "playing") counts for one second at most
        XCTAssertEqual(t.at(2501, now: 60.75).pill, .next(fill: 0.15, countdown: true))
    }

    func testLeavingAndEnteringTheCreditsFillsAfresh() {
        var t = SkipTracker(segments: episode)
        _ = t.at(2500, now: 0)
        _ = t.at(2504, now: 1)
        _ = t.at(2505, now: 2)
        XCTAssertNil(t.at(2400, now: 3).pill)
        XCTAssertEqual(t.at(2500, now: 4).pill, .next(fill: 0, countdown: true))
        XCTAssertEqual(t.at(2501, now: 5).pill, .next(fill: 0.1, countdown: true))
    }

    func testNoCountdownWithAPostCreditsSceneOrAutoplayOff() {
        var scene = SkipTracker(segments: episode)
        XCTAssertEqual(scene.at(2500, duration: 2700).pill, .next(fill: 0, countdown: false))
        var t = SkipTracker(segments: episode)
        _ = t.at(2500, now: 0, autoplay: false)
        let later = t.at(2550, now: 50, autoplay: false)
        XCTAssertEqual(later.pill, .next(fill: 0, countdown: false))
        XCTAssertNil(later.auto)
    }

    func testWatchCreditsDismissesNext() {
        var t = SkipTracker(segments: episode)
        _ = t.at(2500)
        t.creditsDismissed = true
        let step = t.at(2515)
        XCTAssertNil(step.pill)
        XCTAssertNil(step.auto)
        XCTAssertNil(t.at(2501, auto: AutoSkip(credits: true)).auto)
    }

    func testCreditsOfAFilmOrLastEpisodeSkipToTheirEndOrTheEnd() {
        var toEnd = SkipTracker(segments: episode)
        XCTAssertEqual(toEnd.at(2500, duration: 2590.5, hasNext: false).pill, .skip(kind: "credits", alone: true, action: .end))
        var before = SkipTracker(segments: episode)
        XCTAssertEqual(before.at(2500, duration: 2700, hasNext: false).pill, .skip(kind: "credits", alone: true, action: .seek(toSec: 2590)))
    }

    func testAutoCreditsGoesToNextOrEndUnlessASceneFollows() {
        let auto = AutoSkip(credits: true)
        var a = SkipTracker(segments: episode)
        XCTAssertEqual(a.at(2500, auto: auto).auto, .next)
        var b = SkipTracker(segments: episode)
        XCTAssertEqual(b.at(2500, hasNext: false, auto: auto).auto, .end)
        var c = SkipTracker(segments: episode)
        XCTAssertNil(c.at(2500, duration: 2700, auto: auto).auto)
        // a press of «Следующая серия» after the automatic one does nothing
        var d = SkipTracker(segments: episode)
        _ = d.at(2500, auto: auto)
        XCTAssertFalse(d.takeNext())
    }

    func testAutoSkipKindsAreSeparate() {
        let a = AutoSkip(recap: false, intro: true, credits: false)
        XCTAssertTrue(a.isOn("intro"))
        XCTAssertFalse(a.isOn("recap"))
        XCTAssertFalse(a.isOn("credits"))
        XCTAssertFalse(a.isOn("preview"))
    }
}

private extension SkipTracker {
    mutating func at(
        _ sec: Double, now: TimeInterval = 0, playing: Bool = true, duration: Double = 2600,
        hasNext: Bool = true, autoplay: Bool = true, auto: AutoSkip = AutoSkip()
    ) -> Step {
        step(time: sec, now: now, playing: playing, durationSec: duration, hasNext: hasNext, autoplayNext: autoplay, autoSkip: auto)
    }
}
