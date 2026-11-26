import XCTest

/// «Family»: where the other profiles are in a title, on the title's page and in the player, and
/// continuing from their place. Against `scripts/mock-server.py --family` (its second port is the
/// same server with QR sign-in), with `TEST_RUNNER_ANTRESOL_MOCK_FAMILY` set; `TEST_RUNNER_SHOTS_DIR`
/// also gets the pictures as PNG. The mock's profiles: Admin (password), Kiddo (a kid) and Family
/// (an adult, no password), the one these tests sign in as.
final class FamilyUITests: XCTestCase {
    private let server = ProcessInfo.processInfo.environment["ANTRESOL_MOCK_SERVER"] ?? "127.0.0.1:8421"
    private let remote = XCUIRemote.shared
    private let app = XCUIApplication()
    private let language = ProcessInfo.processInfo.environment["ANTRESOL_TEST_LANGUAGE"] ?? "en"
    private let shotsDir = ProcessInfo.processInfo.environment["SHOTS_DIR"] ?? ""

    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["ANTRESOL_MOCK_FAMILY"] != nil,
                          "needs scripts/mock-server.py --family and ANTRESOL_MOCK_FAMILY")
        // A press after a failed step would land on whatever has focus: stop at the first failure.
        continueAfterFailure = false
    }

    // MARK: the title's page

    /// A film: the folded line under the actions (faces in rings, who is where), the list it opens, and Menu back.
    func testTheLineAndTheListOnAFilmsPage() {
        signIn(opening: 19)
        let line = app.buttons["family.line"]
        XCTAssertTrue(line.waitForExistence(timeout: 30), "no «Family» line on the page: \(focusedLabel)")
        XCTAssertEqual(line.label, tr("Family"))
        let value = line.value as? String ?? ""
        XCTAssertTrue(value.hasPrefix("Alex · "), "the line does not start with the newest profile: \(value)")
        XCTAssertTrue(value.contains(language == "ru" ? "34 мин из 1 ч 50 мин" : "34 min of 1 h 50 min"), "no place in the line: \(value)")
        XCTAssertTrue(value.contains(language == "ru" ? "ещё 3" : "3 more"), "no count of the others in the line: \(value)")
        enterPage()
        XCTAssertFalse(line.hasFocus, "the line took the focus from Play")
        sleep(3)
        snapshot("01-film-line")

        XCTAssertTrue(moveFocus(.down, to: line, limit: 3), "focus cannot reach the line: \(focusedLabel)")
        sleep(1)
        snapshot("02-film-line-focused")

        remote.press(.select)
        let alex = app.buttons["family.row.11"]
        XCTAssertTrue(alex.waitForExistence(timeout: 10), "the list did not open: \(focusedLabel)")
        XCTAssertTrue(app.staticTexts[tr("Family")].exists, "no title on the list")
        XCTAssertTrue(alex.label.contains("Alex"), alex.label)
        XCTAssertTrue(alex.label.contains(language == "ru" ? "34 мин из 1 ч 50 мин" : "34 min of 1 h 50 min"), alex.label)
        XCTAssertTrue(alex.label.contains(language == "ru" ? "2 ч назад" : "2 hr ago"), "no time of the last watch: \(alex.label)")
        XCTAssertTrue(alex.label.contains(language == "ru" ? "Продолжить с их места" : "Continue from Their Place"), "no jump: \(alex.label)")
        XCTAssertTrue(waitForFocus(alex), "the list did not start on the newest profile: \(focusedLabel)")
        // a device's account names its person; a profile that finished it has nothing to continue from
        let device = app.buttons["family.row.14"]
        XCTAssertTrue(device.exists && device.label.contains("Living Room · Alex"), "no account of a device: \(device.label)")
        XCTAssertTrue(device.label.contains(language == "ru" ? "1 ч 11 мин из 1 ч 50 мин" : "1 h 11 min of 1 h 50 min"), device.label)
        let finished = app.descendants(matching: .any).matching(identifier: "family.row.12").firstMatch
        XCTAssertTrue(finished.exists, "the one who finished it is not listed")
        XCTAssertTrue(finished.label.contains(tr("Watched")), finished.label)
        XCTAssertFalse(app.buttons["family.row.12"].exists, "a button on a row with nothing to continue")
        XCTAssertFalse(app.staticTexts["family.note"].exists, "an explanatory note under the list")
        sleep(2)
        snapshot("03-film-list")

        remote.press(.menu)
        XCTAssertTrue(line.waitForExistence(timeout: 10) && waitForFocus(line, seconds: 8), "Menu did not come back to the line: \(focusedLabel)")
        XCTAssertFalse(alex.exists, "the list stayed")
        sleep(1)
        snapshot("04-film-line-after-menu")
    }

    /// The longest names the server accepts and a long title: the list wraps them, and the button keeps
    /// its words whole («Continue from Their Place» / «Продолжить с их места»): see the picture.
    func testLongNamesAreNotCut() {
        signIn(opening: 23)
        let line = app.buttons["family.line"]
        XCTAssertTrue(line.waitForExistence(timeout: 30), "no «Family» line on the page: \(focusedLabel)")
        enterPage()
        XCTAssertTrue(moveFocus(.down, to: line, limit: 3), "focus cannot reach the line: \(focusedLabel)")
        remote.press(.select)
        let long = app.buttons["family.row.15"]
        XCTAssertTrue(long.waitForExistence(timeout: 10), "the list did not open: \(focusedLabel)")
        XCTAssertTrue(long.label.contains("Alexandria Konstantinopolskaya-Vishnevskaya"), long.label)
        let device = app.buttons["family.row.16"]
        XCTAssertTrue(device.label.contains("Living Room Projector Upstairs · Alexandria Konstantinopolskaya-Vishnevskaya"), device.label)
        XCTAssertTrue(long.label.contains(language == "ru" ? "Продолжить с их места" : "Continue from Their Place"), long.label)
        // the list scrolls; every row stays inside the panel
        XCTAssertLessThanOrEqual(long.frame.maxX, 1920, "a row runs off the screen: \(long.frame)")
        sleep(2)
        snapshot("05-long-names-list")
        remote.press(.menu)
    }

    /// A series: «Alex · S1 E2 · 17 min» in the line, a next episode and a finished profile in the list, faces on the episode's tile.
    func testASeriesPageNamesTheEpisodes() {
        signIn(opening: 2)
        let line = app.buttons["family.line"]
        XCTAssertTrue(line.waitForExistence(timeout: 30), "no «Family» line on the series page: \(focusedLabel)")
        let value = line.value as? String ?? ""
        XCTAssertTrue(value.hasPrefix(language == "ru" ? "Alex · С1 Э2 · 17 мин" : "Alex · S1, E2 · 17 min"), "the line: \(value)")
        enterPage()
        sleep(3)
        snapshot("10-series-line")

        XCTAssertTrue(moveFocus(.down, to: line, limit: 3), "focus: \(focusedLabel)")
        remote.press(.select)
        let alex = app.buttons["family.row.11"]
        XCTAssertTrue(alex.waitForExistence(timeout: 10), "the list did not open")
        XCTAssertTrue(alex.label.contains(language == "ru" ? "Продолжить с их места" : "Continue from Their Place"), "no jump to the episode: \(alex.label)")
        let sam = app.buttons["family.row.12"]
        XCTAssertTrue(sam.label.contains(language == "ru" ? "Далее: С2 Э1" : "Up next: S2, E1"), "no next episode: \(sam.label)")
        XCTAssertTrue(sam.label.contains(language == "ru" ? "Смотреть С2 Э1" : "S2, E1"), "no way to start it: \(sam.label)")
        let kim = app.descendants(matching: .any).matching(identifier: "family.row.13").firstMatch
        XCTAssertTrue(kim.label.contains(tr("All watched")), "a finished series: \(kim.label)")
        XCTAssertFalse(app.buttons["family.row.13"].exists, "a button for a finished series")
        sleep(2)
        snapshot("11-series-list")
        remote.press(.menu)
        XCTAssertTrue(waitForFocus(line, seconds: 8), "focus: \(focusedLabel)")

        // the episode Alex is in carries his face on its tile: down to the season's tiles, then along to it
        let first = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Episode 1")).firstMatch
        XCTAssertTrue(moveFocus(.down, to: first, limit: 4), "focus cannot reach the episodes: \(focusedLabel)")
        let tile = app.buttons.matching(NSPredicate(format: "label CONTAINS %@ AND value CONTAINS %@", "Episode 2", "Alex")).firstMatch
        XCTAssertTrue(tile.exists, "no tile with Alex's face on it")
        XCTAssertTrue(moveFocus(.right, to: tile, limit: 2), "focus: \(focusedLabel)")
        sleep(2)
        snapshot("12-series-tile-faces")
    }

    /// An episode's page: the profiles at this episode only.
    func testAnEpisodesPage() {
        signIn(opening: 5)
        let line = app.buttons["family.line"]
        XCTAssertTrue(line.waitForExistence(timeout: 30), "no line on the episode's page: \(focusedLabel)")
        XCTAssertTrue((line.value as? String ?? "").contains(language == "ru" ? "17 мин из 45 мин" : "17 min of 45 min"), line.value as? String ?? "")
        enterPage()
        sleep(2)
        snapshot("20-episode-line")
    }

    /// Nobody else has progress in a title: nothing at all, not even the heading.
    func testNothingIsShownWhenNobodyHasProgress() {
        signIn(opening: 101)
        XCTAssertTrue(app.buttons[tr("Resume")].waitForExistence(timeout: 30) || app.buttons[tr("Play")].waitForExistence(timeout: 5), "the page did not open")
        enterPage()
        sleep(5)
        XCTAssertFalse(app.buttons["family.line"].exists, "a line with nobody in it")
        XCTAssertFalse(mockEvents().filter { ($0["path"] as? String) == "/api/items/101/family" }.isEmpty, "the app did not ask")
        snapshot("30-no-line")
    }

    /// A kid is not asked at all (the server lists nobody for a kid).
    func testAKidIsNotAskedAboutTheFamily() {
        signIn(opening: 19, profilesToTheRight: 1)
        XCTAssertTrue(app.buttons[tr("Resume")].waitForExistence(timeout: 30) || app.buttons[tr("Play")].waitForExistence(timeout: 5), "the page did not open")
        sleep(5)
        XCTAssertFalse(app.buttons["family.line"].exists, "a line on a kid's page")
        XCTAssertTrue(mockEvents().filter { ($0["path"] as? String)?.hasSuffix("/family") == true }.isEmpty, "the app asked a kid's server about the family")
    }

    // MARK: continuing

    /// «Play from 0:25»: their position becomes this profile's own (and theirs is not touched), and
    /// the player starts there.
    func testContinuingTakesTheirPositionAndPlaysFromIt() {
        signIn(opening: 22)
        let line = app.buttons["family.line"]
        XCTAssertTrue(line.waitForExistence(timeout: 30), "no line: \(focusedLabel)")
        enterPage()
        XCTAssertTrue(moveFocus(.down, to: line, limit: 3), "focus: \(focusedLabel)")
        remote.press(.select)
        let alex = app.buttons["family.row.11"]
        XCTAssertTrue(alex.waitForExistence(timeout: 10), "the list did not open")
        XCTAssertTrue(waitForFocus(alex), "focus: \(focusedLabel)")
        sleep(1)
        snapshot("40-clip-list")
        remote.press(.select)

        let clock = app.descendants(matching: .any).matching(identifier: "player.position").firstMatch
        XCTAssertTrue(clock.waitForExistence(timeout: 40), "the player did not start: \(focusedLabel)")
        var first: Int?
        let started = Date()
        while first == nil, Date().timeIntervalSince(started) < 20 {
            first = (clock.value as? String).flatMap(Int.init)
            if first == nil { usleep(300_000) }
        }
        let waited = Int(Date().timeIntervalSince(started))
        XCTAssertNotNil(first, "the player has no position")
        XCTAssertGreaterThanOrEqual(first ?? 0, 24, "playback did not start at their place")
        XCTAssertLessThanOrEqual(first ?? 0, 25 + waited + 6, "playback is not near their place")
        snapshot("41-playing-from-their-place")

        let events = mockEvents()
        let adopts = events.filter { ($0["method"] as? String) == "POST" && ($0["path"] as? String) == "/api/progress/22/adopt" }
        XCTAssertEqual(adopts.count, 1, "adopt was asked \(adopts.count) times")
        XCTAssertEqual(json(adopts.first?["body"]) as? [String: Int], ["userId": 11], "adopt names someone else")
        let adoptAt = (events.firstIndex { ($0["path"] as? String) == "/api/progress/22/adopt" }) ?? Int.max
        let asked = events.enumerated().filter { ($0.element["method"] as? String) == "GET" && ($0.element["path"] as? String) == "/api/progress/22" }
        XCTAssertTrue(asked.contains { $0.offset > adoptAt }, "the player did not ask for the position after it was taken")
        // only this profile's own progress is written, and never from before their place
        let writes = events.filter { ($0["method"] as? String) == "PUT" }
        XCTAssertTrue(writes.allSatisfy { ($0["path"] as? String) == "/api/progress/22" && ($0["positionMs"] as? Int ?? 0) >= 24_000 }, "writes: \(writes)")

        for _ in 0..<4 where clock.exists {
            remote.press(.menu)
            sleep(2)
        }
        XCTAssertFalse(clock.exists, "Menu did not leave the player")
        // back on the page the list is there again, with the new place of this profile
        XCTAssertTrue(app.buttons["family.line"].waitForExistence(timeout: 20), "the page lost the line")
    }

    /// A profile that is next in a series just starts the episode (nothing of theirs is taken).
    func testANextEpisodeStartsWithoutTakingAnything() {
        signIn(opening: 2)
        let line = app.buttons["family.line"]
        XCTAssertTrue(line.waitForExistence(timeout: 30), "no line: \(focusedLabel)")
        enterPage()
        XCTAssertTrue(moveFocus(.down, to: line, limit: 3), "focus: \(focusedLabel)")
        remote.press(.select)
        let sam = app.buttons["family.row.12"]
        XCTAssertTrue(sam.waitForExistence(timeout: 10), "the list did not open")
        XCTAssertTrue(moveFocus(.down, to: sam, limit: 3), "focus: \(focusedLabel)")
        remote.press(.select)
        let clock = app.descendants(matching: .any).matching(identifier: "player.position").firstMatch
        XCTAssertTrue(clock.waitForExistence(timeout: 40), "the player did not start")
        sleep(3)
        XCTAssertLessThan(Int(clock.value as? String ?? "") ?? 99, 12, "the episode did not start from its start")
        snapshot("50-next-episode-playing")
        let events = mockEvents()
        XCTAssertTrue(events.filter { ($0["path"] as? String)?.hasSuffix("/adopt") == true }.isEmpty, "a next episode took someone's position")
        XCTAssertFalse(events.filter { ($0["path"] as? String) == "/api/play/2" }.isEmpty, "no playback of the episode's file")
        for _ in 0..<4 where clock.exists {
            remote.press(.menu)
            sleep(2)
        }
    }

    // MARK: the resume prompt

    /// No place of its own and one profile at 1:12:40: «Play» first, their row, and no «Start Over».
    func testFirstTimeWithOnePlaceOffered() {
        signIn(opening: 30)
        openPrompt()
        let own = app.buttons["resume.own"]
        XCTAssertEqual(own.label, tr("Play"), "the first row")
        let alex = app.buttons["resume.family.11"]
        XCTAssertEqual(alex.label, "Alex · 1:12:40", "their row")
        XCTAssertFalse(app.buttons["resume.startOver"].exists, "«Start Over» with nothing to start over from")
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'resume.'")).count, 2)
        XCTAssertTrue(waitForFocus(own), "the prompt does not start on the viewer's own row: \(focusedLabel)")
        sleep(2)
        snapshot("resume-first-time")

        // Play: from the start, taking nothing
        remote.press(.select)
        XCTAssertTrue(wait(40) { self.playRequests().count > 0 }, "no playback after «Play»")
        XCTAssertTrue(adoptEvents().isEmpty, "something was adopted by «Play»")
        leaveEverything()
    }

    /// The viewer is at 34:10: «Resume from 34:10», the two places that are far from it (newest first; the one 20 s from
    /// it and the finished one are not offered), «Start Over»; a row adopts and plays.
    func testResumeWithTwoPlacesOffered() {
        signIn(opening: 31)
        openPrompt()
        XCTAssertEqual(app.buttons["resume.own"].label, language == "ru" ? "Продолжить с 34:10" : "Resume from 34:10")
        XCTAssertEqual(app.buttons["resume.family.11"].label, "Alex · 1:12:40")
        XCTAssertEqual(app.buttons["resume.family.13"].label, "Kim · 51:00")
        XCTAssertFalse(app.buttons["resume.family.14"].exists, "a place 20 s from the viewer's")
        XCTAssertFalse(app.buttons["resume.family.12"].exists, "a profile that finished it")
        XCTAssertTrue(app.buttons["resume.startOver"].exists, "no «Start Over»")
        XCTAssertTrue(waitForFocus(app.buttons["resume.own"]), "focus: \(focusedLabel)")
        sleep(2)
        snapshot("resume-two-members")

        // the order of the rows on the screen: own, Alex, Kim, Start Over
        let ys = ["resume.own", "resume.family.11", "resume.family.13", "resume.startOver"].map { app.buttons[$0].frame.minY }
        XCTAssertEqual(ys, ys.sorted(), "the rows are not in order: \(ys)")

        let alex = app.buttons["resume.family.11"]
        XCTAssertTrue(moveFocus(.down, to: alex, limit: 2), "focus: \(focusedLabel)")
        sleep(1)
        snapshot("resume-two-members-focused")
        remote.press(.select)
        XCTAssertTrue(wait(40) { self.playRequests().count > 0 }, "no playback after the row")
        let events = mockEvents()
        let adopts = adoptEvents(events)
        XCTAssertEqual(adopts.count, 1, "adopt was asked \(adopts.count) times")
        XCTAssertEqual(adopts.first?["path"] as? String, "/api/progress/31/adopt")
        XCTAssertEqual(json(adopts.first?["body"]) as? [String: Int], ["userId": 11])
        let adoptAt = events.firstIndex { ($0["path"] as? String)?.hasSuffix("/adopt") == true } ?? Int.max
        let playAt = events.firstIndex { ($0["method"] as? String) == "POST" && ($0["path"] as? String)?.hasPrefix("/api/play/") == true } ?? -1
        XCTAssertGreaterThan(playAt, adoptAt, "playback began before the place was taken")
        // never anything of theirs is written
        XCTAssertTrue(events.filter { ($0["method"] as? String) == "PUT" }.allSatisfy { ($0["path"] as? String) == "/api/progress/31" })
        leaveEverything()
    }

    /// «Start Over» and «Resume from» on a prompt with rows: no adopt for either.
    func testStartOverAndResumeTakeNothing() {
        signIn(opening: 31)
        openPrompt()
        let startOver = app.buttons["resume.startOver"]
        XCTAssertTrue(moveFocus(.down, to: startOver, limit: 4), "focus: \(focusedLabel)")
        remote.press(.select)
        XCTAssertTrue(wait(40) { self.playRequests().count > 0 }, "no playback after «Start Over»")
        XCTAssertTrue(adoptEvents().isEmpty, "something was adopted")
        leaveEverything()
    }

    /// A series whose next episode is S1 E1: a profile in S1 E2 is offered with its episode, and the row plays THAT
    /// episode (the server's adopt names it).
    func testASeriesOffersAPlaceInAnotherEpisode() {
        signIn(opening: 2)
        openPrompt()
        let alex = app.buttons["resume.family.11"]
        let label = alex.label
        XCTAssertTrue(label.hasPrefix("Alex · "), label)
        XCTAssertTrue(label.hasSuffix(" · 17:00"), label)
        XCTAssertTrue(["S1 E2", "S1, E2", "С1 Э2", "С1, Э2"].contains { label.contains($0) }, "no episode in the row: \(label)")
        // Sam is next (not started) and Kim finished it all: neither is offered
        XCTAssertFalse(app.buttons["resume.family.12"].exists || app.buttons["resume.family.13"].exists)
        XCTAssertTrue(waitForFocus(app.buttons["resume.own"]), "focus: \(focusedLabel)")
        sleep(2)
        snapshot("resume-series-episode")

        XCTAssertTrue(moveFocus(.down, to: alex, limit: 2), "focus: \(focusedLabel)")
        remote.press(.select)
        XCTAssertTrue(wait(40) { self.playRequests().count > 0 }, "no playback after the row")
        let events = mockEvents()
        let adopts = adoptEvents(events)
        XCTAssertEqual(adopts.first?["path"] as? String, "/api/progress/5/adopt", "the place of the other episode was not taken there")
        XCTAssertEqual(json(adopts.first?["body"]) as? [String: Int], ["userId": 11])
        XCTAssertTrue(events.contains { ($0["method"] as? String) == "GET" && ($0["path"] as? String) == "/api/items/5" }, "the other episode was not opened")
        leaveEverything()
    }

    /// The server refuses to adopt (404): no dialog, playback still starts, nothing of theirs is taken.
    func testARefusedAdoptStillPlays() {
        signIn(opening: 33)
        openPrompt()
        let alex = app.buttons["resume.family.11"]
        XCTAssertTrue(moveFocus(.down, to: alex, limit: 2), "focus: \(focusedLabel)")
        remote.press(.select)
        XCTAssertTrue(wait(40) { self.playRequests().count > 0 }, "no playback after a refused adopt")
        XCTAssertEqual(adoptEvents().count, 1, "adopt was not tried")
        XCTAssertFalse(app.alerts.firstMatch.exists, "a dialog after a refused adopt")
        XCTAssertFalse(app.staticTexts[tr("Try Again")].exists || app.buttons[tr("Try Again")].exists, "an error screen")
        leaveEverything()
    }

    /// Nobody is far from the viewer's place (the clip: the viewer at 0:15, the others at 0:25 and 0:12): the
    /// player starts as before, with no prompt, and the server was asked about the family.
    func testNoPromptWhenNobodyIsFarFromTheViewersPlace() {
        signIn(opening: 22)
        let play = app.buttons.matching(NSPredicate(format: "label == %@ OR label == %@", tr("Resume"), tr("Play"))).firstMatch
        XCTAssertTrue(play.waitForExistence(timeout: 30), "no Play: \(focusedLabel)")
        enterPage()
        XCTAssertTrue(waitForFocus(play, seconds: 10), "focus: \(focusedLabel)")
        remote.press(.select)
        let clock = app.descendants(matching: .any).matching(identifier: "player.position").firstMatch
        XCTAssertTrue(clock.waitForExistence(timeout: 40), "the player did not start by itself: \(focusedLabel)")
        XCTAssertFalse(app.buttons["resume.own"].exists, "a prompt with nobody to offer")
        XCTAssertFalse(mockEvents().filter { ($0["path"] as? String) == "/api/items/22/family" }.isEmpty, "the app did not ask")
        leavePlayer(clock)
    }

    /// A kid is not asked: «Resume» plays at once (at 34:10 of the 60 s clip, so the player may be gone by itself
    /// before it is looked at: the mock's play request is the sign), and the server is never asked about the family.
    func testAKidGetsNoPromptAndIsNotAsked() {
        signIn(opening: 31, profilesToTheRight: 1)
        let play = app.buttons.matching(NSPredicate(format: "label == %@ OR label == %@", tr("Resume"), tr("Play"))).firstMatch
        XCTAssertTrue(play.waitForExistence(timeout: 30), "no Play: \(focusedLabel)")
        enterPage()
        XCTAssertTrue(waitForFocus(play, seconds: 10), "focus: \(focusedLabel)")
        remote.press(.select)
        XCTAssertTrue(wait(40) { self.playRequests().count > 0 }, "no playback: \(focusedLabel)")
        XCTAssertFalse(app.buttons["resume.own"].exists, "a prompt for a kid")
        XCTAssertTrue(mockEvents().filter { ($0["path"] as? String)?.hasSuffix("/family") == true }.isEmpty, "a kid's app asked about the family")
        leaveEverything()
    }

    /// «Continue from Their Place» on the page has chosen already: no prompt after it, whoever else is far away.
    func testContinuingFromTheFamilyListDoesNotAskAgain() {
        signIn(opening: 31)
        let line = app.buttons["family.line"]
        XCTAssertTrue(line.waitForExistence(timeout: 30), "no line: \(focusedLabel)")
        enterPage()
        XCTAssertTrue(moveFocus(.down, to: line, limit: 3), "focus: \(focusedLabel)")
        remote.press(.select)
        let alex = app.buttons["family.row.11"]
        XCTAssertTrue(alex.waitForExistence(timeout: 10), "the list did not open")
        XCTAssertTrue(waitForFocus(alex), "focus: \(focusedLabel)")
        remote.press(.select)
        XCTAssertTrue(wait(40) { self.playRequests().count > 0 }, "no playback: \(focusedLabel)")
        XCTAssertFalse(app.buttons["resume.own"].exists, "the prompt came after the viewer had chosen")
        XCTAssertEqual(adoptEvents().count, 1)
        leaveEverything()
    }

    /// An episode the viewer picked from the list is just that episode: Alex is in S1 E2 (and the series' Play offers
    /// him there, see above), so nothing is offered on S1 E1, which nobody else is in: it starts at once.
    func testAnEpisodePickedFromTheListIsNotOfferedOtherEpisodes() {
        signIn(opening: 2)
        let tile = focusEpisodeTile("Episode 1")
        XCTAssertTrue(tile.exists)
        remote.press(.playPause)
        XCTAssertTrue(wait(40) { self.playRequests().count > 0 }, "the episode did not start by itself: \(focusedLabel)")
        XCTAssertFalse(app.buttons["resume.own"].exists, "a prompt on an episode nobody else is in")
        XCTAssertTrue(adoptEvents().isEmpty)
        leaveEverything()
    }

    /// ...and an episode somebody is in offers them there, as «Alex · 17:00» (the same episode: no code).
    func testAnEpisodePickedFromTheListOffersThoseInIt() {
        signIn(opening: 2)
        focusEpisodeTile("Episode 2")
        remote.press(.playPause)
        let alex = app.buttons["resume.family.11"]
        XCTAssertTrue(alex.waitForExistence(timeout: 40), "no prompt on the episode Alex is in: \(focusedLabel)")
        XCTAssertEqual(alex.label, "Alex · 17:00", "the row of somebody in the very episode names no episode")
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'resume.family.'")).count, 1)
        sleep(1)
        snapshot("resume-episode-picked")
    }

    /// «Restart» is a place chosen already: no prompt, nothing offered, nothing adopted.
    func testStartingFromTheBeginningHasNoPrompt() {
        signIn(opening: 31)
        let play = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@ OR label BEGINSWITH %@", tr("Resume"), tr("Play"))).firstMatch
        XCTAssertTrue(play.waitForExistence(timeout: 30), "no Resume: \(focusedLabel)")
        enterPage()
        XCTAssertTrue(waitForFocus(play, seconds: 10), "focus: \(focusedLabel)")
        let restart = app.buttons[tr("Restart")]
        XCTAssertTrue(moveFocus(.right, to: restart, limit: 2), "no Restart: \(focusedLabel)")
        remote.press(.select)
        XCTAssertTrue(wait(40) { self.playRequests().count > 0 }, "no playback after Restart")
        XCTAssertFalse(app.buttons["resume.own"].exists, "a prompt after Restart")
        XCTAssertTrue(adoptEvents().isEmpty)
        leaveEverything()
    }

    /// The next episode that follows by itself (Up Next) starts by itself, though Alex is far from the viewer in it
    /// (S1 E2, 17:00 against 0:15): no prompt, nothing adopted.
    func testTheNextEpisodeThatFollowsByItselfHasNoPrompt() {
        signIn(opening: 2)
        openPrompt()
        // the series' Continue offered Alex in S1 E2; the viewer goes on with S1 E1 from 0:15 (the clip's credits are at 0:18)
        XCTAssertTrue(app.buttons["resume.family.11"].exists)
        remote.press(.select)
        let next = app.buttons["player.upNext.next"]
        XCTAssertTrue(next.waitForExistence(timeout: 40), "no Next Episode at the credits: \(focusedLabel)")
        XCTAssertTrue(wait(25) { self.mockEvents().contains { ($0["method"] as? String) == "GET" && ($0["path"] as? String) == "/api/items/5" } },
                      "the next episode did not open by itself")
        let clock = app.descendants(matching: .any).matching(identifier: "player.position").firstMatch
        XCTAssertTrue(wait(30) { self.playRequests().count >= 2 }, "the next episode did not start by itself: \(focusedLabel)")
        XCTAssertFalse(app.buttons["resume.own"].exists, "a prompt on the episode that follows by itself")
        XCTAssertTrue(clock.waitForExistence(timeout: 20) || playRequests().count >= 2)
        XCTAssertTrue(adoptEvents().isEmpty, "something was adopted")
        leaveEverything()
    }

    /// Presses Play / Resume on the page and waits for the prompt.
    private func openPrompt() {
        // a series' button names the episode: «Play S1 E1»
        let play = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@ OR label BEGINSWITH %@", tr("Resume"), tr("Play"))).firstMatch
        XCTAssertTrue(play.waitForExistence(timeout: 30), "no Play: \(focusedLabel)")
        enterPage()
        XCTAssertTrue(waitForFocus(play, seconds: 10), "focus: \(focusedLabel)")
        remote.press(.select)
        XCTAssertTrue(app.buttons["resume.own"].waitForExistence(timeout: 40), "no resume prompt: \(focusedLabel)")
    }

    /// Down from the series page's actions to the tile of an episode ("Episode 1"), along to it when it is not the first.
    @discardableResult
    private func focusEpisodeTile(_ title: String) -> XCUIElement {
        let line = app.buttons["family.line"]
        XCTAssertTrue(line.waitForExistence(timeout: 30), "no line on the series page: \(focusedLabel)")
        enterPage()
        let first = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Episode 1")).firstMatch
        XCTAssertTrue(moveFocus(.down, to: first, limit: 5), "focus cannot reach the episodes: \(focusedLabel)")
        let tile = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", title)).firstMatch
        XCTAssertTrue(moveFocus(.right, to: tile, limit: 3), "focus cannot reach \(title): \(focusedLabel)")
        return tile
    }

    private func adoptEvents(_ events: [[String: Any]]? = nil) -> [[String: Any]] {
        (events ?? mockEvents()).filter { ($0["method"] as? String) == "POST" && ($0["path"] as? String)?.hasSuffix("/adopt") == true }
    }

    private func playRequests() -> [[String: Any]] {
        mockEvents().filter { ($0["method"] as? String) == "POST" && ($0["path"] as? String)?.hasPrefix("/api/play/") == true }
    }

    /// Menu until the player is gone (a position past the clip's end closes it by itself), and a moment for its last write.
    private func leaveEverything() {
        let clock = app.descendants(matching: .any).matching(identifier: "player.position").firstMatch
        sleep(2)
        for _ in 0..<4 where clock.exists {
            remote.press(.menu)
            sleep(2)
        }
        sleep(1)
    }

    // MARK: the player

    /// «Family» in the transport bar: a row takes the player to their place, and while it is only looked
    /// at the position saved stays the one before it; «Back to …» goes back.
    func testThePlayersFamilyMenu() throws {
        let clock = playFromTheSavedPositionAndPeekAtAlex()
        snapshot("62-at-their-place")
        // the menu again: «Back to 0:15» comes first, and takes the player back
        remote.press(.select)
        sleep(2)
        snapshot("63-family-menu-back-row")
        remote.press(.select)
        XCTAssertTrue(wait(10) { (Int(clock.value as? String ?? "") ?? 99) <= 22 }, "Back did not return: \(clock.value as? String ?? "")")
        sleep(2)
        snapshot("64-back-again")
        leavePlayer(clock)
        // what is saved is where this profile was, never the place only looked at
        let writes = clipWrites()
        XCTAssertFalse(writes.isEmpty, "nothing was saved on leaving")
        XCTAssertTrue(writes.allSatisfy { $0 < 22_000 }, "the place only looked at was saved: \(writes)")
        print("progress writes of the clip (positionMs): \(writes)")
    }

    /// Once the player has played five seconds at their place it is this profile's own: saved from there on.
    func testAPeekedPlaceBecomesOursOncePlayedOn() throws {
        let clock = playFromTheSavedPositionAndPeekAtAlex()
        // the bar's Select paused the player: it plays on from their place, and five seconds there end the hold; the
        // periodic write (every 10 s) then takes the real position
        remote.press(.playPause)
        XCTAssertTrue(wait(30) { self.clipWrites().contains { $0 >= 30_000 } }, "the place played on was not saved: \(clipWrites())")
        leavePlayer(clock)
        let writes = clipWrites()
        XCTAssertTrue(writes.allSatisfy { $0 >= 18_000 }, "a position from before the film was written: \(writes)")
        // looking at their place (0:25 to 0:30) saved nothing of it: the place before, then the real position from 0:30 on
        XCTAssertTrue(writes.allSatisfy { $0 < 22_000 || $0 >= 30_000 }, "the place was saved before it was played on: \(writes)")
        print("progress writes of the clip (positionMs): \(writes)")
    }

    /// Plays the clip from its saved 0:15, opens «Family» in the transport bar and goes to Alex's 0:25; the
    /// player's clock.
    private func playFromTheSavedPositionAndPeekAtAlex() -> XCUIElement {
        signIn(opening: 22)
        let play = app.buttons.matching(NSPredicate(format: "label == %@ OR label == %@", tr("Resume"), tr("Play"))).firstMatch
        XCTAssertTrue(play.waitForExistence(timeout: 30), "no Play: \(focusedLabel)")
        enterPage()
        XCTAssertTrue(waitForFocus(play, seconds: 10), "focus: \(focusedLabel)")
        remote.press(.select)
        let clock = app.descendants(matching: .any).matching(identifier: "player.position").firstMatch
        XCTAssertTrue(clock.waitForExistence(timeout: 40), "the player did not start")
        sleep(3)
        XCTAssertGreaterThanOrEqual(Int(clock.value as? String ?? "") ?? 0, 14, "not from the saved 0:15")

        // The transport bar (Select shows it, Up goes to its buttons): Audio, Subtitles, Quality, Skip Automatically,
        // then Family (a skip pill may come first); Right until the focus is on it. The bar's buttons are the
        // system's: the menu is found by its title, or the icon's name.
        remote.press(.select)
        sleep(2)
        remote.press(.up)
        sleep(2)
        func onFamily() -> Bool {
            let focused = app.descendants(matching: .any).element(matching: NSPredicate(format: "hasFocus == true"))
            return focused.exists && focused.identifier != "family.line" && [tr("Family"), "person.2"].contains { focused.label.contains($0) || focused.identifier.contains($0) }
        }
        var trail: [String] = [focusedLabel]
        for _ in 0..<9 where !onFamily() {
            remote.press(.right)
            sleep(1)
            trail.append(focusedLabel)
        }
        XCTAssertTrue(onFamily(), "no «Family» in the transport bar: \(trail)")
        snapshot("60-transport-family-button")
        remote.press(.select)
        sleep(2)
        snapshot("61-family-menu")
        // the newest profile first (Alex, 0:25); a press goes there
        remote.press(.select)
        XCTAssertTrue(wait(10) { (Int(clock.value as? String ?? "") ?? 0) >= 24 }, "the player did not go to their place: \(clock.value as? String ?? "")")
        // a jump in the player's own menu is a place chosen: no prompt comes up over it
        XCTAssertFalse(app.buttons["resume.own"].exists, "a prompt after a jump from the player's menu")
        return clock
    }

    /// Progress writes of the clip (positionMs), in order.
    private func clipWrites() -> [Int] {
        mockEvents().filter { ($0["method"] as? String) == "PUT" && ($0["path"] as? String) == "/api/progress/22" }.compactMap { $0["positionMs"] as? Int }
    }

    /// Menu until the player is gone, and a moment for its last write.
    private func leavePlayer(_ clock: XCUIElement) {
        for _ in 0..<4 where clock.exists {
            remote.press(.menu)
            sleep(2)
        }
        XCTAssertFalse(clock.exists, "Menu did not leave the player")
        sleep(2)
    }

    // MARK: helpers

    /// Fresh session on the mock's second port as the adult «Family» profile (`profilesToTheRight` 2), or the kid (1),
    /// with the page of item `id` opened by its link.
    private func signIn(opening id: Int, profilesToTheRight: Int = 2) {
        mock("POST", "/mock/reset")
        app.launchArguments += ["-AntresolOpenURL", "antresol://item/\(id)"]
        app.launchArguments += ["-AntresolResetSession", "YES", "-AntresolServerURL", pairingServer, "-AppleLanguages", "(\(language))"]
        app.launchArguments += ["-tv.mode", "channels", "-tv.filter", "all"]
        app.launch()
        XCTAssertTrue(app.staticTexts[tr("Sign in with your phone")].waitForExistence(timeout: 30), "no QR sign-in screen")
        XCTAssertTrue(waitForFocus(app.buttons[tr("Sign In with the Remote")]), "focus: \(focusedLabel)")
        remote.press(.select)
        XCTAssertTrue(app.staticTexts[tr("Who's watching?")].waitForExistence(timeout: 30))
        sleep(2)
        for _ in 0..<profilesToTheRight { remote.press(.right) }
        remote.press(.select)
    }

    /// A page opened by a link starts with the focus in the sidebar: Right goes into the page.
    private func enterPage() {
        let focused = app.descendants(matching: .any).element(matching: NSPredicate(format: "hasFocus == true"))
        for _ in 0..<3 where !focused.exists || focused.frame.minX < 20 {
            remote.press(.right)
            sleep(1)
        }
    }

    private func tr(_ key: String) -> String {
        guard language != "en" else { return key }
        let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("AntresolTV/Resources/\(language).lproj/Localizable.strings").path
        return (NSDictionary(contentsOfFile: path) as? [String: String])?[key] ?? key
    }

    private var pairingServer: String {
        let parts = server.split(separator: ":")
        guard parts.count == 2, let port = Int(parts[1]) else { return server }
        return "\(parts[0]):\(port + 1)"
    }

    /// A request to the mock's second port (its `/mock/…` hooks); the answer's body, nil when there was none.
    @discardableResult
    private func mock(_ method: String, _ path: String) -> Data? {
        let parts = pairingServer.split(separator: ":")
        guard parts.count == 2, let port = Int(parts[1]) else { return nil }
        var input: InputStream?
        var output: OutputStream?
        Stream.getStreamsToHost(withName: String(parts[0]), port: port, inputStream: &input, outputStream: &output)
        guard let input, let output else { return nil }
        input.open()
        output.open()
        defer {
            input.close()
            output.close()
        }
        let request = Array("\(method) \(path) HTTP/1.1\r\nHost: \(pairingServer)\r\nConnection: close\r\nContent-Length: 0\r\n\r\n".utf8)
        guard output.write(request, maxLength: request.count) == request.count else { return nil }
        var answer = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            let count = input.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            answer.append(buffer, count: count)
        }
        guard let headerEnd = answer.range(of: Data("\r\n\r\n".utf8)),
              String(decoding: answer.prefix(12), as: UTF8.self).hasSuffix("200")
        else { return nil }
        return answer.subdata(in: headerEnd.upperBound..<answer.count)
    }

    private func json(_ body: Any?) -> Any? {
        (body as? String).flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) }
    }

    /// What the mock's second port was asked since the last `/mock/reset`.
    private func mockEvents() -> [[String: Any]] {
        guard let data = mock("GET", "/mock/events"),
              let events = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else {
            XCTFail("the mock's second port did not list its requests")
            return []
        }
        return events
    }

    private func waitForFocus(_ element: XCUIElement, seconds: Int = 5) -> Bool {
        for _ in 0..<(seconds * 2) {
            if element.exists && element.hasFocus { return true }
            usleep(500_000)
        }
        return element.exists && element.hasFocus
    }

    @discardableResult
    private func moveFocus(_ direction: XCUIRemote.Button, to element: XCUIElement, limit: Int) -> Bool {
        for _ in 0..<limit {
            if element.exists && element.hasFocus { return true }
            remote.press(direction)
            sleep(1)
        }
        return element.exists && element.hasFocus
    }

    private func wait(_ seconds: Int, _ condition: () -> Bool) -> Bool {
        for _ in 0..<(seconds * 2) {
            if condition() { return true }
            usleep(500_000)
        }
        return condition()
    }

    private var focusedLabel: String {
        let focused = app.descendants(matching: .any).element(matching: NSPredicate(format: "hasFocus == true"))
        return focused.exists ? "\(focused.identifier) \(focused.label) \(focused.frame)" : "none"
    }

    /// The screen as an attachment, and as `tv-<language>-family-<name>.png` in `SHOTS_DIR`.
    private func snapshot(_ name: String) {
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        guard !shotsDir.isEmpty else { return }
        try? FileManager.default.createDirectory(atPath: shotsDir, withIntermediateDirectories: true)
        try? shot.pngRepresentation.write(to: URL(fileURLWithPath: shotsDir).appendingPathComponent("tv-\(language)-family-\(name).png"))
    }
}
