import XCTest

/// What the screenshot tests do not show, checked against `scripts/mock-server.py` (its
/// second port is the same server with QR sign-in).
final class RuntimeTests: XCTestCase {
    private let server = ProcessInfo.processInfo.environment["ANTRESOL_MOCK_SERVER"] ?? "127.0.0.1:8421"
    private let remote = XCUIRemote.shared
    private let app = XCUIApplication()

    override func setUp() {
        continueAfterFailure = true
    }

    /// The QR sign-in screen is the root of the sign-in flow: Menu on the server screen
    /// (Change Server) comes back to it, Menu on it leaves the app.
    func testSignInMenu() {
        launch(server: pairingServer)
        let title = app.staticTexts["Sign in with your phone"]
        XCTAssertTrue(title.waitForExistence(timeout: 30), "no QR sign-in screen")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Code expires in")).firstMatch
            .waitForExistence(timeout: 10), "no sign-in code")
        snapshot("rt-01-qr-sign-in")

        XCTAssertTrue(moveFocus(.right, to: app.buttons["Change Server"], limit: 3), "focus: \(focusedLabel)")
        remote.press(.select)
        XCTAssertTrue(title.waitForNonExistence(timeout: 10), "the server screen did not open")
        sleep(2)
        snapshot("rt-02-server-screen")
        remote.press(.menu)
        XCTAssertTrue(title.waitForExistence(timeout: 10), "Menu on the server screen did not come back")
        XCTAssertEqual(app.state, .runningForeground)
        sleep(2)

        remote.press(.menu)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 10) || app.state == .runningBackgroundSuspended,
                      "Menu on the QR screen did not leave the app: state \(app.state.rawValue)")
        snapshot("rt-03-left-the-app")
    }

    /// The TV tab opens on the last channel; the player plays it, zaps, opens the options
    /// row and the audio list with focus where the viewer expects it, and Menu comes back
    /// to the channel's row.
    func testLivePlayer() {
        signInAsKid()
        XCTAssertTrue(openTV(), "no TV tab: \(focusedLabel)")
        // The mock's last channel is 2.
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Комедии")).firstMatch
        XCTAssertTrue(waitForFocus(row), "the list did not open on the last channel: \(focusedLabel)")
        snapshot("rt-10-tv-last-channel")

        // The banner goes away only once the picture plays.
        remote.press(.select)
        let hints = app.staticTexts["Switch Channel"]
        XCTAssertTrue(hints.waitForExistence(timeout: 10), "no banner")
        XCTAssertTrue(picture("2 · Комедии").waitForExistence(timeout: 5), "not on channel 2")
        XCTAssertTrue(hints.waitForNonExistence(timeout: 30), "channel 2 did not start playing")
        snapshot("rt-11-live-playing")

        remote.press(.up)
        XCTAssertTrue(picture("3 · Драмы").waitForExistence(timeout: 5), "Up did not switch to channel 3")
        snapshot("rt-12-zap-banner")
        XCTAssertTrue(hints.waitForNonExistence(timeout: 30), "channel 3 did not start playing")

        // Select: the options row, focus on Audio (the stream has three voices).
        remote.press(.select)
        let audio = app.buttons["live.audio"]
        XCTAssertTrue(audio.waitForExistence(timeout: 5), "no Audio control")
        XCTAssertTrue(waitForFocus(audio), "the options row did not take focus on Audio: \(focusedLabel)")
        snapshot("rt-13-options-row")

        // The list opens on the voice that plays (the device's language, the second of
        // three); a pick closes it, focus back on Audio.
        remote.press(.select)
        XCTAssertTrue(waitForFocus(app.buttons["live.track.English"]), "the audio list did not open on the playing voice: \(focusedLabel)")
        snapshot("rt-14-audio-list")
        remote.press(.up)
        sleep(1)
        remote.press(.select)
        XCTAssertTrue(waitForFocus(audio), "focus did not return to Audio after a pick: \(focusedLabel)")
        // Opened again at once, while the list that closed may still be leaving.
        remote.press(.select)
        XCTAssertTrue(waitForFocus(app.buttons["live.track.Русский"]), "the audio list did not open on the picked voice: \(focusedLabel)")
        snapshot("rt-15-audio-picked")

        // Menu: the list, the options row, then the player.
        for _ in 0..<4 where picture("3 · Драмы").exists {
            remote.press(.menu)
            sleep(2)
        }
        XCTAssertFalse(picture("3 · Драмы").exists, "Menu did not leave the player")
        XCTAssertTrue(waitForFocus(row), "back on the TV tab, focus is not on the channel's row: \(focusedLabel)")
        snapshot("rt-16-back-on-tv-tab")
    }

    /// A last channel far down the list (the mock's second port: the 18th of 24, off the
    /// first screen): the TV tab scrolls to it and puts focus on it.
    func testTVTabOpensOnAFarLastChannel() {
        signInOnSecondPort()
        XCTAssertTrue(openTV(), "no TV tab: \(focusedLabel)")
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Канал 18")).firstMatch
        XCTAssertTrue(waitForFocus(row), "the list did not open on the last channel: \(focusedLabel)")
        let frame = row.frame
        XCTAssertTrue(frame.minY >= 0 && frame.maxY <= 1080, "the focused row is off the screen: \(frame)")
        snapshot("rt-50-tv-far-last-channel")
        // It stays there (nothing takes focus back once the list settled).
        sleep(2)
        XCTAssertTrue(row.exists && row.hasFocus, "focus left the last channel: \(focusedLabel)")
    }

    /// «Избранные каналы первыми» (the mock's second port: on, channel 3 starred): the list
    /// keeps the server's order, the favourite on top; the category list starts with
    /// Favourites and All; rows without a logo that loads show the guide's icon or the
    /// initials. Turned off in Settings, the list is by number again.
    func testChannelListFavouritesFirst() {
        signInOnSecondPort()
        XCTAssertNotNil(mock("POST", "/mock/reset"), "no answer from the mock's second port")
        XCTAssertTrue(openTV(), "no TV tab: \(focusedLabel)")
        let starred = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Драмы")).firstMatch
        let first = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Все фильмы")).firstMatch
        XCTAssertTrue(starred.waitForExistence(timeout: 20) && first.waitForExistence(timeout: 5), "no channel rows")
        // Up to the top of the list, where the favourite is.
        for _ in 0..<30 where !starred.hasFocus {
            remote.press(.up)
            usleep(300_000)
        }
        sleep(2)
        XCTAssertLessThan(starred.frame.minY, first.frame.minY, "the favourite (3) is not above channel 1")
        snapshot("rt-70-tv-favourites-first")

        // The category list: Favourites, then All, then the categories.
        let categories = app.buttons["tv.categories"]
        XCTAssertTrue(moveFocus(.up, to: categories, limit: 4), "no category button: \(focusedLabel)")
        remote.press(.select)
        let favourites = app.buttons["tv.category.favorites"]
        let all = app.buttons["tv.category.all"]
        XCTAssertTrue(favourites.waitForExistence(timeout: 10) && all.exists, "no category list")
        XCTAssertLessThan(favourites.frame.minY, all.frame.minY, "Favourites is not first")
        sleep(1)
        snapshot("rt-71-tv-categories")
        remote.press(.menu)
        sleep(2)

        // Settings: «Избранные каналы первыми» off.
        XCTAssertTrue(openSection("Kiddo", prefix: true, showing: app.buttons["Switch Profile"]), "no Settings: \(focusedLabel)")
        sleep(2)
        remote.press(.down)
        sleep(1)
        moveFocus(.right, to: setting("Video Quality"), limit: 3)
        let row = setting("Favourite Channels First")
        XCTAssertTrue(moveFocus(.down, to: row, limit: 8), "no Favourite Channels First row: \(focusedLabel)")
        XCTAssertTrue(row.label.contains("On"), "not on to start with: \(row.label)")
        remote.press(.select)
        XCTAssertTrue(wait(10) { row.label.contains("Off") }, "the row did not turn off: \(row.label)")
        snapshot("rt-72-settings-favourites-first-off")
        XCTAssertTrue(mockEvents().contains { $0["method"] as? String == "PUT" && $0["path"] as? String == "/api/channels/prefs" }, "no PUT /api/channels/prefs")

        XCTAssertTrue(openTV(), "no TV tab: \(focusedLabel)")
        XCTAssertTrue(wait(15) { first.exists && starred.exists && first.frame.minY < starred.frame.minY }, "the list is not by number after the change")
        snapshot("rt-73-tv-by-number")
        mock("POST", "/mock/reset")
    }

    /// With focus off its buttons the hero moves on by itself every 8 s, unless Reduce
    /// Motion is on (Settings > Accessibility > Motion), when it stays.
    func testHeroAutoAdvance() {
        signInAsKid()
        // Onto the first shelf: the hero does not move under its own buttons' focus.
        remote.press(.right)
        sleep(2)
        let card = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Big Buck Demo")).firstMatch
        XCTAssertTrue(moveFocus(.down, to: card, limit: 2), "focus: \(focusedLabel)")
        let dots = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", "Featured ")).firstMatch
        XCTAssertTrue(dots.waitForExistence(timeout: 10), "no hero page dots")
        let reduceMotion = UIAccessibility.isReduceMotionEnabled
        // A run that is meant to see the setting on, or off, says so (CI's two steps): a
        // setting left on in the simulator would turn the main run into the other one.
        switch ProcessInfo.processInfo.environment["ANTRESOL_EXPECT_REDUCE_MOTION"] {
        case "1": XCTAssertTrue(reduceMotion, "Reduce Motion is not on in this simulator")
        case "0": XCTAssertFalse(reduceMotion, "Reduce Motion is on in this simulator")
        default: break
        }
        let first = dots.label
        snapshot(reduceMotion ? "rt-22-hero-reduce-motion" : "rt-20-hero")
        var seen = Set([first])
        for _ in 0..<12 {
            sleep(1)
            seen.insert(dots.label)
        }
        snapshot(reduceMotion ? "rt-23-hero-reduce-motion-12s-later" : "rt-21-hero-12s-later")
        if reduceMotion {
            XCTAssertEqual(seen, [first], "the hero moved with Reduce Motion on")
        } else {
            XCTAssertGreaterThan(seen.count, 1, "the hero did not move in 12 s: \(focusedLabel)")
        }
    }

    /// A song the server transcodes (the mock's second port, the album's third song)
    /// starts without waiting for the app's question about the stream, which the mock
    /// answers after 6 s: the player's own request comes before that answer and the
    /// clock runs before it. A seek after that reloads the stream at the new position
    /// (`t=` in the mock's record), as a transcoded song needs, and the clock goes on
    /// from there.
    func testTranscodedSong() {
        signInOnSecondPort()

        // The first album of Home's shelves (as the screenshot tests reach it).
        remote.press(.right)
        sleep(2)
        let album = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Sample Record")).firstMatch
        for _ in 0..<4 where !(album.exists && album.hasFocus) {
            remote.press(.down)
            sleep(1)
        }
        XCTAssertTrue(moveFocus(.right, to: album, limit: 6), "focus: \(focusedLabel)")
        remote.press(.select)
        XCTAssertTrue(app.buttons["Play"].waitForExistence(timeout: 20))
        sleep(3)
        for _ in 0..<3 {
            remote.press(.down)
            sleep(1)
        }
        XCTAssertTrue(focusedLabel.contains("Track Number 3"), "focus: \(focusedLabel)")
        XCTAssertNotNil(mock("POST", "/mock/reset"), "no answer from the mock's second port")

        remote.press(.select)
        let position = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Playback Position")).firstMatch
        XCTAssertTrue(position.waitForExistence(timeout: 20), "no Now Playing")
        func clock() -> Int? {
            guard let parts = (position.value as? String)?.split(separator: ":").map({ Int($0) }), parts.count == 2,
                  let minutes = parts[0], let seconds = parts[1]
            else { return nil }
            return minutes * 60 + seconds
        }
        func wait(seconds limit: TimeInterval, until reached: (Int) -> Bool) -> Date? {
            let from = Date()
            while Date().timeIntervalSince(from) < limit {
                if let now = clock(), reached(now) { return Date() }
                usleep(200_000)
            }
            return nil
        }
        // The clock leaves 0:00 before the mock answers the app's own request.
        let moved = wait(seconds: 20) { $0 > 0 }
        XCTAssertNotNil(moved, "the song did not start")
        snapshot("rt-30-transcoded-song-playing")
        XCTAssertTrue(moveFocus(.up, to: position, limit: 3), "focus: \(focusedLabel)")

        // By 0:13 the app knows the song is transcoded (the answer came at about 0:06).
        XCTAssertNotNil(wait(seconds: 30) { $0 >= 13 }, "the song did not reach 0:13: \(clock() ?? -1)")
        let stream = { (events: [[String: Any]]) in events.filter { $0["path"] as? String == "/api/tracks/17/stream" } }
        let before = stream(mockEvents())
        let players = before.filter { ($0["agent"] as? String ?? "").contains("AppleCoreMedia") }
        let asked = before.filter { !($0["agent"] as? String ?? "").contains("AppleCoreMedia") }
        let answered = asked.compactMap { $0["answered"] as? Double }.min()
        XCTAssertNotNil(answered, "the app's own request about the stream was not answered: \(before)")
        if let answered, let first = players.compactMap({ $0["t"] as? Double }).min(), let moved {
            XCTAssertLessThan(first, answered, "the player asked for the song only after the app's question was answered")
            XCTAssertLessThan(moved.timeIntervalSince1970, answered, "the clock ran only after the app's question was answered")
            print("transcoded song: player asked \(String(format: "%.1f", answered - first)) s, clock ran \(String(format: "%.1f", answered - moved.timeIntervalSince1970)) s before the answer")
        } else {
            XCTFail("the player did not ask for the song: \(before)")
        }

        // Ten seconds back: the stream is asked for again from there, and plays on from there.
        let from = clock() ?? 0
        remote.press(.left)
        sleep(4)
        let landed = clock() ?? -1
        let target = from - 10
        XCTAssertTrue(landed >= target && landed <= target + 7, "the seek from 0:\(from) did not land near 0:\(max(0, target)): 0:\(landed)")
        XCTAssertTrue(app.buttons["Pause"].exists, "not playing after the seek")
        let reloads = stream(mockEvents()).dropFirst(before.count).compactMap { event -> Double? in
            guard let query = event["query"] as? String,
                  let value = query.split(separator: "&").first(where: { $0.hasPrefix("t=") })?.dropFirst(2)
            else { return nil }
            return Double(value)
        }
        XCTAssertTrue(reloads.contains { abs($0 - Double(target)) <= 2 }, "the stream was not asked for again near \(target) s: \(reloads)")
        snapshot("rt-31-transcoded-song-after-seek")
    }

    /// The saved position survives a failed progress request and the error screen's Try
    /// Again: the mock (second port) answers the player's `GET /api/progress/19` with 503
    /// once; Try Again asks again, the film resumes at its saved 0:15, and nothing near
    /// 0 is ever written for it.
    func testTryAgainResumesAtTheSavedPosition() {
        signInOnSecondPort()
        remote.press(.right)
        sleep(2)
        let card = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Big Buck Demo")).firstMatch
        XCTAssertTrue(moveFocus(.down, to: card, limit: 2), "focus: \(focusedLabel)")
        XCTAssertNotNil(mock("POST", "/mock/reset"), "no answer from the mock's second port")
        XCTAssertNotNil(mock("POST", "/mock/fail-progress/19"))

        remote.press(.select)
        let tryAgain = app.buttons["Try Again"]
        XCTAssertTrue(tryAgain.waitForExistence(timeout: 20), "no error screen for the failed progress request")
        XCTAssertTrue(waitForFocus(tryAgain), "focus: \(focusedLabel)")
        snapshot("rt-40-progress-failed")
        remote.press(.select)
        // The card asks before it resumes; the prompt is there again after the retry.
        let resume = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Resume")).firstMatch
        XCTAssertTrue(resume.waitForExistence(timeout: 20), "no resume prompt after Try Again")
        XCTAssertTrue(resume.label.contains("0:15"), "the prompt is not for the saved position: \(resume.label)")
        XCTAssertTrue(waitForFocus(resume), "focus: \(focusedLabel)")
        snapshot("rt-41-resume-prompt-after-retry")
        remote.press(.select)

        // The player's clock (file seconds; debug builds expose it): from 0:15 on.
        let clock = app.descendants(matching: .any).matching(identifier: "player.position").firstMatch
        XCTAssertTrue(clock.waitForExistence(timeout: 30), "the player did not start")
        var first: Int?
        let started = Date()
        while first == nil, Date().timeIntervalSince(started) < 20 {
            first = (clock.value as? String).flatMap(Int.init)
            if first == nil { usleep(300_000) }
        }
        let waited = Int(Date().timeIntervalSince(started))
        XCTAssertNotNil(first, "the player has no position")
        XCTAssertGreaterThanOrEqual(first ?? 0, 14, "playback did not start at the saved position")
        XCTAssertLessThanOrEqual(first ?? 0, 15 + waited + 5, "playback is not near the saved position")
        snapshot("rt-42-resumed-at-saved-position")
        // Long enough for the periodic progress write (10 s), then Menu for the final one.
        sleep(12)
        let later = (clock.value as? String).flatMap(Int.init) ?? 0
        XCTAssertGreaterThan(later, first ?? 0, "the clock does not run")
        for _ in 0..<4 where clock.exists {
            remote.press(.menu)
            sleep(2)
        }
        XCTAssertFalse(clock.exists, "Menu did not leave the player")
        sleep(2)

        let events = mockEvents()
        let asked = events.filter { $0["method"] as? String == "GET" && $0["path"] as? String == "/api/progress/19" }
        XCTAssertGreaterThanOrEqual(asked.count, 2, "Try Again did not ask for the saved position again: \(asked)")
        XCTAssertEqual(asked.first?["failed"] as? Bool, true, "the first progress request was not the failed one")
        let writes = events.filter { $0["method"] as? String == "PUT" && $0["path"] as? String == "/api/progress/19" }
            .compactMap { $0["positionMs"] as? Int }
        XCTAssertFalse(writes.isEmpty, "no progress write at all")
        XCTAssertTrue(writes.allSatisfy { $0 >= 14_000 }, "a position before the saved one was written: \(writes)")
        print("mock progress writes for item 19 (positionMs): \(writes); progress requests: \(asked.count)")
    }

    /// Try Again asks the way the card was opened: a series card of Continue Watching
    /// (the mock's second port) asks where to start and plays the series' next episode,
    /// whose progress request the mock fails once. After Try Again the resume prompt is
    /// there again; the episode does not just start at its saved position.
    func testTryAgainAsksAgainForASeriesCard() {
        signInOnSecondPort()
        remote.press(.right)
        sleep(2)
        let first = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Big Buck Demo")).firstMatch
        XCTAssertTrue(moveFocus(.down, to: first, limit: 2), "focus: \(focusedLabel)")
        for _ in 0..<5 where !focusedLabel.contains("Test Show") {
            remote.press(.right)
            sleep(1)
        }
        XCTAssertTrue(focusedLabel.contains("Test Show"), "focus: \(focusedLabel)")
        XCTAssertNotNil(mock("POST", "/mock/reset"), "no answer from the mock's second port")
        // The series' next episode is item 4.
        XCTAssertNotNil(mock("POST", "/mock/fail-progress/4"))

        remote.press(.select)
        let tryAgain = app.buttons["Try Again"]
        XCTAssertTrue(tryAgain.waitForExistence(timeout: 20), "no error screen for the failed progress request")
        XCTAssertTrue(waitForFocus(tryAgain), "focus: \(focusedLabel)")
        remote.press(.select)
        // ("Resume from …": Home's hero behind the player has a plain "Resume".)
        let resume = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Resume from")).firstMatch
        XCTAssertTrue(resume.waitForExistence(timeout: 20), "no resume prompt after Try Again for a series card")
        XCTAssertTrue(resume.label.contains("0:15"), "the prompt is not for the saved position: \(resume.label)")
        snapshot("rt-45-series-resume-prompt-after-retry")
        let asked = mockEvents().filter { $0["method"] as? String == "GET" && $0["path"] as? String == "/api/progress/4" }
        XCTAssertEqual(asked.count, 2, "the episode's saved position was not asked for twice: \(asked)")
        XCTAssertEqual(asked.first?["failed"] as? Bool, true, "the first progress request was not the failed one")
    }

    /// Two external channels of one guide source have the same programme ids (the mock's
    /// second port: Alpha and Beta, the 13th and 14th rows, below the first screen). Down
    /// from Alpha's programme lands on Beta's, the grid scrolls with it, and Select opens
    /// Beta's programme.
    func testGuideMovesBetweenRowsWithTheSameProgrammeIds() {
        // The TV tab opens in the guide (the view the viewer chose last).
        app.launchArguments += ["-tv.mode", "guide"]
        signInOnSecondPort()
        XCTAssertTrue(openTV(), "no TV tab: \(focusedLabel)")
        let focused = app.descendants(matching: .any).element(matching: NSPredicate(format: "hasFocus == true"))
        func onScreen() -> Bool { focused.exists && focused.frame.minY >= 0 && focused.frame.maxY <= 1080 }
        for _ in 0..<24 where !focusedLabel.contains("Альфа ТВ") {
            remote.press(.down)
            sleep(1)
        }
        XCTAssertTrue(focusedLabel.contains("100 · Альфа ТВ, Альфа-новости"), "focus did not reach Alpha's programme: \(focusedLabel)")
        XCTAssertTrue(onScreen(), "Alpha's programme is off the screen: \(focusedLabel)")
        snapshot("rt-60-guide-alpha")

        remote.press(.down)
        sleep(2)
        XCTAssertTrue(focusedLabel.contains("101 · Бета ТВ, Бета-кино"), "Down did not land on Beta's programme: \(focusedLabel)")
        XCTAssertTrue(onScreen(), "the grid did not follow focus to Beta's row: \(focusedLabel)")
        snapshot("rt-61-guide-beta")

        // The row after them, with ids of its own: the grid still follows.
        remote.press(.down)
        sleep(2)
        XCTAssertTrue(focusedLabel.contains("102 · Гамма ТВ, Гамма-спорт"), "Down did not go on to the next row: \(focusedLabel)")
        XCTAssertTrue(onScreen(), "the grid did not follow focus to the last row: \(focusedLabel)")
        remote.press(.up)
        sleep(2)
        XCTAssertTrue(focusedLabel.contains("101 · Бета ТВ, Бета-кино"), "Up did not come back to Beta's programme: \(focusedLabel)")

        remote.press(.select)
        XCTAssertTrue(app.staticTexts["Бета-кино"].waitForExistence(timeout: 10), "Select did not open Beta's programme")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Бета ТВ")).firstMatch.exists, "not Beta's channel")
        XCTAssertFalse(app.staticTexts["Альфа-новости"].exists)
        snapshot("rt-62-guide-beta-programme")
    }

    /// The skip pills (the mock's second port: the film has an intro at 0:18–0:30 and
    /// credits to its end from 0:44, and it resumes at 0:15). «Skip Intro» shows with the
    /// transport bar hidden and Select presses it; «Skip Automatically» saves Intro on the
    /// profile; the film opened again skips its intro by itself with a note and Go Back,
    /// which returns into it; «Skip Credits» of a film ends it. The pills are the player's
    /// contextual actions, outside the app's accessibility tree: the debug probe
    /// `player.skip` says which one is over the video (with the transport bar hidden).
    func testSkipPills() {
        signInOnSecondPort()
        XCTAssertNotNil(mock("POST", "/mock/reset"), "no answer from the mock's second port")
        let clock = app.descendants(matching: .any).matching(identifier: "player.position").firstMatch
        let pill = app.descendants(matching: .any).matching(identifier: "player.skip").firstMatch
        let showing = { (kind: String) in self.wait(30) { (pill.value as? String) == kind } }
        playFilmFromItsSavedPosition()
        XCTAssertTrue(clock.waitForExistence(timeout: 30), "the player did not start")

        XCTAssertTrue(showing("intro"), "no Skip Intro at the intro: clock \(seconds(clock) ?? -1)")
        sleep(1)
        snapshot("rt-60-skip-intro")
        remote.press(.select)
        XCTAssertTrue(wait(10) { (self.seconds(clock) ?? 0) >= 30 }, "Select did not skip to 0:30: \(seconds(clock) ?? -1)")
        XCTAssertTrue(showing(""), "Skip Intro stayed after the intro")
        snapshot("rt-61-after-skip-intro")

        // The transport bar: «Skip Automatically», the fourth button (Audio, Subtitles,
        // Quality, it), turns Intro (its second row) on.
        remote.press(.select)
        sleep(2)
        remote.press(.up)
        sleep(2)
        for _ in 0..<3 {
            remote.press(.right)
            sleep(1)
        }
        snapshot("rt-62-auto-skip-button")
        remote.press(.select)
        sleep(2)
        remote.press(.down)
        sleep(1)
        snapshot("rt-63-auto-skip-menu")
        remote.press(.select)
        sleep(2)
        let saved = mockEvents().filter { $0["path"] as? String == "/api/me/playback-prefs/auto-skip" }
        XCTAssertEqual(saved.compactMap { $0["body"] as? String }, [#"{"intro":true}"#], "Intro was not saved alone: \(saved)")
        leavePlayer(clock)

        // Opened again: the intro goes by itself, with the note and Go Back.
        playFilmFromItsSavedPosition()
        XCTAssertTrue(clock.waitForExistence(timeout: 30), "the player did not start again")
        let note = app.descendants(matching: .any).matching(identifier: "player.skip.note").firstMatch
        XCTAssertTrue(note.waitForExistence(timeout: 20), "no note of the automatic skip: clock \(seconds(clock) ?? -1)")
        XCTAssertGreaterThanOrEqual(seconds(clock) ?? 0, 29, "the intro was not skipped by itself")
        snapshot("rt-64-intro-skipped")
        // Go Back over the video once the transport bar (up since the start) is gone.
        XCTAssertTrue(wait(8) { (pill.value as? String) == "undo" }, "no Go Back beside the note")
        sleep(1)
        snapshot("rt-64b-go-back")
        remote.press(.select)
        XCTAssertTrue(wait(10) { (self.seconds(clock) ?? 99) < 26 }, "Go Back did not return into the intro: \(seconds(clock) ?? -1)")
        XCTAssertTrue(showing("intro"), "back in the intro, no Skip Intro (it must not skip again)")
        snapshot("rt-65-back-in-the-intro")

        // The film's credits run to its end: Skip Credits ends it.
        XCTAssertTrue(wait(45) { (pill.value as? String) == "credits" }, "no Skip Credits at the credits: clock \(seconds(clock) ?? -1)")
        sleep(1)
        snapshot("rt-66-skip-credits")
        remote.press(.select)
        XCTAssertTrue(clock.waitForNonExistence(timeout: 15), "Skip Credits of a film did not end it")
    }

    /// At the credits of an episode with a next one (the mock's second port: from 0:18;
    /// the series card resumes its episode at 0:15) the Up Next panel offers «Next Episode»,
    /// filling over 10 s, beside «Watch Credits», and then plays it.
    func testCreditsCountDownToTheNextEpisode() {
        signInOnSecondPort()
        remote.press(.right)
        sleep(2)
        let first = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Big Buck Demo")).firstMatch
        XCTAssertTrue(moveFocus(.down, to: first, limit: 2), "focus: \(focusedLabel)")
        for _ in 0..<5 where !focusedLabel.contains("Test Show") {
            remote.press(.right)
            sleep(1)
        }
        XCTAssertTrue(focusedLabel.contains("Test Show"), "focus: \(focusedLabel)")
        XCTAssertNotNil(mock("POST", "/mock/reset"), "no answer from the mock's second port")
        remote.press(.select)
        let resume = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Resume from")).firstMatch
        XCTAssertTrue(resume.waitForExistence(timeout: 20), "no resume prompt")
        remote.press(.select)

        let next = app.buttons["player.upNext.next"]
        XCTAssertTrue(next.waitForExistence(timeout: 30), "no Next Episode at the credits")
        XCTAssertTrue(app.buttons["Watch Credits"].exists, "no Watch Credits beside it")
        sleep(4)
        snapshot("rt-67-next-episode-filling")
        // Ten seconds from the credits' start the next episode (item 5) opens by itself.
        XCTAssertTrue(wait(20) {
            self.mockEvents().contains { $0["method"] as? String == "GET" && $0["path"] as? String == "/api/items/5" }
        }, "the next episode did not open after the countdown")
        sleep(3)
        snapshot("rt-68-next-episode-playing")
    }

    // MARK: - Helpers

    /// Big Buck Demo from Continue Watching, resumed at its saved 0:15.
    private func playFilmFromItsSavedPosition() {
        if !focusedLabel.contains("Big Buck Demo") {
            remote.press(.right)
            sleep(2)
            let card = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Big Buck Demo")).firstMatch
            XCTAssertTrue(moveFocus(.down, to: card, limit: 2), "focus: \(focusedLabel)")
        }
        remote.press(.select)
        let resume = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Resume from")).firstMatch
        XCTAssertTrue(resume.waitForExistence(timeout: 20), "no resume prompt")
        XCTAssertTrue(waitForFocus(resume), "focus: \(focusedLabel)")
        remote.press(.select)
    }

    /// Menu until the player is gone.
    private func leavePlayer(_ clock: XCUIElement) {
        for _ in 0..<5 where clock.exists {
            remote.press(.menu)
            sleep(2)
        }
        XCTAssertFalse(clock.exists, "Menu did not leave the player")
        sleep(2)
    }

    /// The player's file position in whole seconds (debug builds).
    private func seconds(_ clock: XCUIElement) -> Int? {
        (clock.value as? String).flatMap(Int.init)
    }

    /// Whether `condition` holds within `limit` seconds.
    private func wait(_ limit: TimeInterval, until condition: () -> Bool) -> Bool {
        let from = Date()
        while Date().timeIntervalSince(from) < limit {
            if condition() { return true }
            usleep(300_000)
        }
        return condition()
    }

    /// «Отдельная история на этом устройстве» on the second port's adult profile: the row
    /// shows the state, a history is picked on its page, the shell starts again on Home
    /// with that history's Continue Watching, Off asks the web's merge question, and a new
    /// history is made by name.
    func testSeparateHistoryOnThisDevice() {
        mock("POST", "/mock/reset")
        launch(server: pairingServer)
        XCTAssertTrue(app.staticTexts["Sign in with your phone"].waitForExistence(timeout: 30), "no QR sign-in screen")
        XCTAssertTrue(waitForFocus(app.buttons["Sign In with the Remote"]), "focus: \(focusedLabel)")
        remote.press(.select)
        XCTAssertTrue(app.staticTexts["Who's watching?"].waitForExistence(timeout: 30))
        sleep(2)
        remote.press(.right)
        remote.press(.right)
        remote.press(.select)
        XCTAssertTrue(app.buttons["Details"].waitForExistence(timeout: 30))
        sleep(3)

        openSeparateHistory()
        XCTAssertTrue(setting("Separate History on This Device").label.hasSuffix("Off"), setting("Separate History on This Device").label)
        snapshot("rt-history-01-row")
        remote.press(.select)
        let livingRoom = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Living Room")).firstMatch
        XCTAssertTrue(livingRoom.waitForExistence(timeout: 10), "no history listed")
        sleep(2)
        snapshot("rt-history-02-page")
        XCTAssertTrue(moveFocus(.down, to: livingRoom, limit: 3), "focus: \(focusedLabel)")
        remote.press(.select)
        // The shell starts again on Home, which loads this history's Continue Watching.
        XCTAssertTrue(app.buttons["Details"].waitForExistence(timeout: 30), "not back on Home")
        sleep(3)
        snapshot("rt-history-03-home")
        let events = mockEvents()
        guard let put = events.lastIndex(where: { ($0["method"] as? String) == "PUT" && ($0["path"] as? String) == "/api/me/devices/current/history" }) else {
            return XCTFail("no switch was sent")
        }
        XCTAssertTrue(events[put...].contains { ($0["path"] as? String) == "/api/home" }, "Home was not loaded again")
        XCTAssertEqual(json(events[put]["body"]) as NSDictionary?, ["accountId": 20, "separate": true] as NSDictionary)

        openSeparateHistory()
        XCTAssertTrue(setting("Separate History on This Device").label.hasSuffix("Living Room"), setting("Separate History on This Device").label)
        remote.press(.select)
        XCTAssertTrue(livingRoom.waitForExistence(timeout: 10))
        sleep(2)
        XCTAssertTrue(livingRoom.hasFocus, "the current history should start focused: \(focusedLabel)")
        XCTAssertTrue(moveFocus(.up, to: app.buttons["Off"].firstMatch, limit: 3), "focus: \(focusedLabel)")
        remote.press(.select)
        XCTAssertTrue(app.buttons["Move to My Profile"].firstMatch.waitForExistence(timeout: 10), "no merge question")
        sleep(1)
        snapshot("rt-history-04-off")
        XCTAssertTrue(moveFocus(.down, to: app.buttons["Keep Apart"].firstMatch, limit: 3), "focus: \(focusedLabel)")
        remote.press(.select)
        XCTAssertTrue(app.buttons["Details"].waitForExistence(timeout: 30), "not back on Home")
        sleep(3)
        let off = mockEvents().last { ($0["method"] as? String) == "PUT" }
        XCTAssertEqual(json(off?["body"]) as NSDictionary?, ["merge": false, "separate": false] as NSDictionary)

        openSeparateHistory()
        remote.press(.select)
        let new = app.buttons["New History…"].firstMatch
        XCTAssertTrue(new.waitForExistence(timeout: 10))
        XCTAssertTrue(moveFocus(.down, to: new, limit: 4), "focus: \(focusedLabel)")
        remote.press(.select)
        let field = app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10), "no name field")
        sleep(1)
        snapshot("rt-history-05-name")
        // Select opens the keyboard on the field; Return submits it.
        remote.press(.select)
        sleep(2)
        field.typeText("Kitchen\n")
        sleep(2)
        let create = app.buttons["Create"].firstMatch
        if create.exists && create.isEnabled {
            moveFocus(.down, to: create, limit: 3)
            remote.press(.select)
        }
        XCTAssertTrue(app.buttons["Details"].waitForExistence(timeout: 30), "not back on Home: \(focusedLabel)")
        let made = mockEvents()
        XCTAssertTrue(made.contains { ($0["method"] as? String) == "POST" && ($0["path"] as? String) == "/api/me/managed" }, "no history made")
        openSeparateHistory()
        XCTAssertTrue(setting("Separate History on This Device").label.hasSuffix("Kitchen"), setting("Separate History on This Device").label)
        snapshot("rt-history-06-new-on")
    }

    /// Fresh session on the mock's second port (QR sign-in, the mock's test hooks), then
    /// the passwordless second profile through the profile picker.
    private func signInOnSecondPort() {
        launch(server: pairingServer)
        XCTAssertTrue(app.staticTexts["Sign in with your phone"].waitForExistence(timeout: 30), "no QR sign-in screen")
        XCTAssertTrue(waitForFocus(app.buttons["Sign In with the Remote"]), "focus: \(focusedLabel)")
        remote.press(.select)
        XCTAssertTrue(app.staticTexts["Who's watching?"].waitForExistence(timeout: 30))
        sleep(2)
        remote.press(.right)
        remote.press(.select)
        XCTAssertTrue(app.buttons["Details"].waitForExistence(timeout: 30))
        sleep(3)
    }

    /// A request to the mock's second port (its `/mock/…` hooks); the answer's body, nil
    /// when there was none. A plain socket: the runner has no exception for clear-text
    /// HTTP of its own.
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

    /// A request body the mock kept, as JSON.
    private func json(_ body: Any?) -> [String: Any]? {
        (body as? String).flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
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

    /// The mock's port with QR sign-in: the one after the main port.
    private var pairingServer: String {
        let parts = server.split(separator: ":")
        guard parts.count == 2, let port = Int(parts[1]) else { return server }
        return "\(parts[0]):\(port + 1)"
    }

    /// The live player's picture, labelled with the channel on screen.
    private func picture(_ label: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label)).firstMatch
    }

    private func launch(server: String) {
        app.launchArguments += ["-AntresolResetSession", "YES", "-AntresolServerURL", server, "-AppleLanguages", "(en)"]
        app.launch()
    }

    /// Fresh session, then the passwordless second profile.
    private func signInAsKid() {
        launch(server: server)
        XCTAssertTrue(app.staticTexts["Who's watching?"].waitForExistence(timeout: 30))
        sleep(2)
        remote.press(.right)
        remote.press(.select)
        XCTAssertTrue(app.buttons["Details"].waitForExistence(timeout: 30))
        sleep(3)
    }

    /// Opens the TV tab from the sidebar and waits for the list.
    private func openTV() -> Bool {
        openSection("TV", showing: app.buttons["Guide"])
    }

    /// Opens the sidebar entry labelled `title` (the profile's: beginning with it) and waits
    /// for `marker`.
    private func openSection(_ title: String, prefix: Bool = false, showing marker: XCUIElement) -> Bool {
        let focused = app.descendants(matching: .any).element(matching: NSPredicate(format: "hasFocus == true"))
        func inSidebar() -> Bool { focused.exists && focused.frame.minX < 1 && focused.frame.width < 600 && focused.frame.height < 150 }
        for _ in 0..<2 {
            for _ in 0..<6 where !inSidebar() {
                remote.press(.left)
                sleep(1)
            }
            let entries = app.buttons.matching(NSPredicate(format: prefix ? "label BEGINSWITH %@" : "label == %@", title)).allElementsBoundByIndex
            guard inSidebar(), let entry = entries.first(where: { $0.frame.minX < 1 && $0.frame.width < 600 }) else { continue }
            for _ in 0..<12 where inSidebar() {
                let delta = entry.frame.midY - focused.frame.midY
                if abs(delta) < 4 { break }
                remote.press(delta > 0 ? .down : .up)
                sleep(1)
            }
            guard inSidebar(), abs(entry.frame.midY - focused.frame.midY) < 4 else { continue }
            remote.press(.select)
            if marker.waitForExistence(timeout: 20) { return true }
        }
        return false
    }

    /// A settings row by its title (its label also carries the value).
    private func setting(_ title: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", title)).firstMatch
    }

    /// From the profile column of Settings to the separate-history row, and into its page.
    private func openSeparateHistory() {
        XCTAssertTrue(openSection("Family", prefix: true, showing: app.buttons["Switch Profile"]), "no Settings: \(focusedLabel)")
        sleep(2)
        remote.press(.down)
        sleep(1)
        moveFocus(.right, to: setting("Video Quality"), limit: 3)
        XCTAssertTrue(moveFocus(.down, to: setting("Separate History on This Device"), limit: 8), "focus: \(focusedLabel)")
    }

    /// Whether `element` gets focus within `seconds`, without a press.
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

    private var focusedLabel: String {
        let focused = app.descendants(matching: .any).element(matching: NSPredicate(format: "hasFocus == true"))
        return focused.exists ? "\(focused.identifier) \(focused.label) \(focused.frame)" : "none"
    }

    private func snapshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
