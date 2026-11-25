import XCTest

/// What the screenshot tests do not show, checked against `scripts/mock-server.py` (its
/// second port is the same server with QR sign-in).
final class RuntimeTests: XCTestCase {
    private let server = ProcessInfo.processInfo.environment["ANTRESOL_MOCK_SERVER"] ?? "127.0.0.1:8421"
    private let remote = XCUIRemote.shared
    private let app = XCUIApplication()
    /// `en` (the default) or `ru`: the language the app runs in (`TEST_RUNNER_ANTRESOL_TEST_LANGUAGE`).
    private let language = ProcessInfo.processInfo.environment["ANTRESOL_TEST_LANGUAGE"] ?? "en"

    override func setUp() {
        continueAfterFailure = true
    }

    /// The QR sign-in screen is the root of the sign-in flow: Menu on the server screen
    /// (Change Server) comes back to it, Menu on it leaves the app.
    func testSignInMenu() {
        launch(server: pairingServer)
        let title = app.staticTexts[tr("Sign in with your phone")]
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

    /// The setup screen's address field, reached with the remote and typed into. Discovery is off
    /// (`-AntresolNoDiscovery`) so no server of the network can take focus from the control Select is
    /// pressed on, and Select is pressed only on a control the test saw focused: a test never connects
    /// to a server it was not given.
    private func typeAddress(_ address: String) {
        app.launchArguments += ["-AntresolResetSession", "YES", "-AntresolNoDiscovery", "YES", "-AppleLanguages", "(\(language))"]
        app.launch()
        let enter = app.buttons[tr("Enter Address with the Remote")]
        XCTAssertTrue(enter.waitForExistence(timeout: 30), "no setup screen")
        XCTAssertTrue(waitForFocus(enter), "focus is not on «Enter Address with the Remote»: \(focusedLabel)")
        remote.press(.select)
        let field = app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10), "no address field")
        XCTAssertTrue(waitForFocus(field), "focus is not on the address field: \(focusedLabel)")
        remote.press(.select)
        sleep(1)
        field.typeText(address + "\n")
    }

    /// A typed address whose name does not resolve (`.invalid` never does): the screen says the server
    /// cannot be reached. It does not ask for a second press that would send a password over plain http
    /// to a host that is not there.
    func testAnAddressThatDoesNotResolveIsNotOfferedUnencrypted() {
        continueAfterFailure = false
        typeAddress("no-such-host.invalid")
        // by the beginning of the text: a query by a long identifier is refused
        func line(_ key: String) -> XCUIElement {
            app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", String(tr(key).prefix(30)))).firstMatch
        }
        let unreachable = line("Couldn't reach the server. Check the address and that the server is running.")
        let unencrypted = line("This connection isn't encrypted: your password would cross the internet in the clear. Select Connect again to use it anyway.")
        XCTAssertTrue(unreachable.waitForExistence(timeout: 60) || unencrypted.exists, "no answer: \(focusedLabel)")
        sleep(1)
        snapshot("rt-80-address-does-not-resolve")
        XCTAssertTrue(unreachable.exists, "the screen does not say the server cannot be reached")
        XCTAssertFalse(unencrypted.exists, "the viewer was asked to accept plain http to a host that does not resolve")
    }

    /// The address the viewer types reaches the mock (the home network's http, one attempt) and goes on to
    /// the profile picker: what `ServerAddress.connect` hands `AppState.connect` is kept as the server.
    func testATypedAddressConnectsToTheServer() {
        continueAfterFailure = false
        typeAddress(server)
        XCTAssertTrue(app.staticTexts[tr("Who's watching?")].waitForExistence(timeout: 30), "no profile picker: \(focusedLabel)")
        sleep(2)
        snapshot("rt-81-typed-address-connected")
    }

    /// The TV tab opens on the last channel; the player plays it, zaps, opens the options
    /// row and the audio list with focus where the viewer expects it, and Menu comes back
    /// to the channel's row.
    func testLivePlayer() {
        signInAsKid()
        XCTAssertTrue(openTV(), "no TV tab: \(focusedLabel)")
        // The mock's last channel is 2.
        let row = channelRow("Комедии")
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

        // Right: the options row, focus on Audio (the stream has three voices).
        remote.press(.right)
        let audio = app.buttons["live.audio"]
        XCTAssertTrue(audio.waitForExistence(timeout: 5), "no Audio control")
        XCTAssertTrue(waitForFocus(audio), "the options row did not take focus on Audio: \(focusedLabel)")
        snapshot("rt-13-options-row")

        // The list opens on the voice that plays (the profile's first language, Russian,
        // the master's DEFAULT; the device is English); a pick closes it, focus back on Audio.
        remote.press(.select)
        XCTAssertTrue(waitForFocus(app.buttons["live.track.Русский"]), "the audio list did not open on the profile's voice: \(focusedLabel)")
        snapshot("rt-14-audio-list")
        remote.press(.down)
        sleep(1)
        remote.press(.select)
        XCTAssertTrue(waitForFocus(audio), "focus did not return to Audio after a pick: \(focusedLabel)")
        // Opened again at once, while the list that closed may still be leaving.
        remote.press(.select)
        XCTAssertTrue(waitForFocus(app.buttons["live.track.English"]), "the audio list did not open on the picked voice: \(focusedLabel)")
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

    /// A channel whose audio the Apple TV cannot decode (the mock's second port after
    /// `POST /mock/external-audio`: the list says `remuxAudio` and offers the server's relay)
    /// plays through the relay, with the media key on the playlist and on every link in it, and
    /// the provider's own address is never asked; the next channel, which does not say, plays
    /// from the provider as before and its relay is left alone.
    func testAChannelWhoseAudioNeedsTheServerPlaysThroughTheRelay() {
        XCTAssertNotNil(mock("POST", "/mock/reset"), "no answer from the mock's second port")
        XCTAssertNotNil(mock("POST", "/mock/external-audio"), "the mock does not know the external channels")
        addTeardownBlock { _ = self.mock("POST", "/mock/reset") }
        signInOnSecondPort()
        XCTAssertTrue(openTV(), "no TV tab: \(focusedLabel)")
        // the list opens on the last channel, the first of the two
        let row = channelRow("Звук через сервер")
        XCTAssertTrue(waitForFocus(row), "the list did not open on the channel: \(focusedLabel)")
        remote.press(.select)
        XCTAssertTrue(picture("200 · Звук через сервер").waitForExistence(timeout: 10), "not on channel 200")
        snapshot("rt-96-live-relayed-banner")
        let path = { (event: [String: Any]) in event["path"] as? String ?? "" }
        let keyed = { (event: [String: Any]) in (event["query"] as? String ?? "").contains("mk=") }
        // the player asks for the stream's rendition and its segments, each keyed: the mock
        // answers 401 to a relay request without the key, so only a keyed chain plays
        XCTAssertTrue(waitForEvent(timeout: 40) { path($0).hasPrefix("/api/channels/live/ext/200/0/relay/video-") && path($0).hasSuffix(".ts") && keyed($0) },
                      "no segment through the relay")
        XCTAssertTrue(app.staticTexts["Switch Channel"].waitForNonExistence(timeout: 30), "the relayed channel did not start playing")
        snapshot("rt-96b-live-relayed-playing")
        let relayed = mockEvents().filter { path($0).hasPrefix("/api/channels/live/ext/200/") }
        XCTAssertTrue(relayed.allSatisfy(keyed), "a relay request without the media key: \(relayed.filter { !keyed($0) })")
        XCTAssertFalse(mockEvents().contains { path($0).hasPrefix("/provider/200/") }, "the provider's own stream was asked for")

        // the next channel plays from its provider
        remote.press(.up)
        XCTAssertTrue(picture("201 · Звук напрямую").waitForExistence(timeout: 10), "Up did not switch to channel 201")
        snapshot("rt-97-live-direct-banner")
        XCTAssertTrue(waitForEvent(timeout: 40) { path($0).hasPrefix("/provider/201/video-") && path($0).hasSuffix(".ts") }, "no segment from the provider")
        XCTAssertTrue(app.staticTexts["Switch Channel"].waitForNonExistence(timeout: 30), "the direct channel did not start playing")
        snapshot("rt-97b-live-direct-playing")
        XCTAssertFalse(mockEvents().contains { path($0).hasPrefix("/api/channels/live/ext/201/") }, "channel 201 went through the relay")
    }

    /// A last channel far down the list (the mock's second port: the 18th of 24, off the
    /// first screen): the TV tab scrolls to it and puts focus on it.
    func testTVTabOpensOnAFarLastChannel() {
        signInOnSecondPort()
        XCTAssertTrue(openTV(), "no TV tab: \(focusedLabel)")
        let row = channelRow("Канал 18")
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
        let starred = channelRow("Драмы")
        let first = channelRow("Все фильмы")
        // The list opens on the last channel (the 18th, far down; rows off the screen do not
        // exist yet): up to the top, where the favourite is.
        XCTAssertTrue(channelRow("Канал 18").waitForExistence(timeout: 20), "no channel rows")
        sleep(2)
        for _ in 0..<30 where !(starred.exists && starred.hasFocus) {
            remote.press(.up)
            usleep(400_000)
        }
        sleep(2)
        XCTAssertTrue(starred.exists && first.exists, "no rows of channels 3 and 1: \(focusedLabel)")
        XCTAssertLessThan(starred.frame.minY, first.frame.minY, "the favourite (3) is not above channel 1")
        snapshot("rt-70-tv-favourites-first")

        // The category button's list: Favourites, then All, then the categories; Menu closes it as it was.
        XCTAssertTrue(focusCategoryButton(), "no category button: \(focusedLabel)")
        remote.press(.select)
        let favourites = app.buttons["tv.category.favorites"]
        let all = app.buttons["tv.category.all"]
        XCTAssertTrue(favourites.waitForExistence(timeout: 10) && all.exists, "no category list")
        XCTAssertLessThan(favourites.frame.minY, all.frame.minY, "Favourites is not first")
        snapshot("rt-71-tv-categories")
        remote.press(.menu)
        XCTAssertTrue(wait(10) { !all.exists }, "Menu did not close the category list")

        // Settings: «Избранные каналы первыми» off.
        XCTAssertTrue(openSection("Kiddo", prefix: true, showing: app.buttons[tr("Switch Profile")]), "no Settings: \(focusedLabel)")
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
        sleep(3)
        for _ in 0..<30 where !(first.exists && first.hasFocus) {
            remote.press(.up)
            usleep(400_000)
        }
        sleep(2)
        XCTAssertTrue(first.exists && starred.exists && first.frame.minY < starred.frame.minY, "the list is not by number after the change: \(focusedLabel)")
        snapshot("rt-73-tv-by-number")
        mock("POST", "/mock/reset")
    }

    /// The TV remote as TiviMate has it (the mock's second port: 24 channels and channel 25
    /// of the adult category, which the server lists first): the category button beside the
    /// view switch opens the list of categories, choosing one narrows the list; the adult
    /// category is last and its channel is nowhere else; rows without a logo show their coloured tile; the number pad
    /// tunes to a channel by its number («1_», then 12 at its second digit, 1 after the
    /// pause), channel up zaps, and a number outside the adult category does not reach its
    /// channel.
    func testTiviMateRemote() {
        signInOnSecondPort()
        XCTAssertNotNil(mock("POST", "/mock/reset"), "no answer from the mock's second port")
        XCTAssertTrue(openTV(), "no TV tab: \(focusedLabel)")
        let far = channelRow("Канал 18")
        XCTAssertTrue(waitForFocus(far, seconds: 20), "the list did not open on the last channel: \(focusedLabel)")
        sleep(2)
        snapshot("rt-80-tv-list-and-card")

        let adultRow = channelRow("Ночной канал")
        XCTAssertFalse(adultRow.exists, "the adult channel is in All")
        XCTAssertTrue(focusCategoryButton(), "no category button: \(focusedLabel)")
        remote.press(.select)
        let all = app.buttons["tv.category.all"]
        let adult = app.buttons["tv.category.cat:ai:adult"]
        XCTAssertTrue(all.waitForExistence(timeout: 10) && adult.exists, "no category list")
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "tv.category.")).allElementsBoundByIndex
        XCTAssertEqual(rows.map(\.frame.minY).max(), adult.frame.minY, "the adult category is not last")

        // The list opens on the current category (All); Select on another narrows the list to it.
        XCTAssertTrue(waitForFocus(all), "the list did not open on All: \(focusedLabel)")
        XCTAssertTrue(moveFocus(.down, to: adult, limit: 14), "no way down to the adult category: \(focusedLabel)")
        remote.press(.select)
        XCTAssertTrue(adultRow.waitForExistence(timeout: 10), "the adult category does not list its channel")
        XCTAssertFalse(far.exists, "the adult category lists other channels")
        snapshot("rt-81-tv-adult-category")
        // Back to All: its channels take focus, on the last one.
        XCTAssertTrue(focusCategoryButton(), "no category button: \(focusedLabel)")
        remote.press(.select)
        XCTAssertTrue(waitForFocus(adult), "the list did not open on the adult category: \(focusedLabel)")
        XCTAssertTrue(moveFocus(.up, to: all, limit: 14), "no way back up to All: \(focusedLabel)")
        remote.press(.select)
        XCTAssertTrue(far.waitForExistence(timeout: 10) && !adultRow.exists, "All is not back")
        XCTAssertTrue(waitForFocus(far, seconds: 10), "Select on a category did not move focus to its channels: \(focusedLabel)")

        // The number pad: 1, 2 → channel 12 at once (25 is the highest: two digits).
        let pad = app.buttons["tv.numberpad"]
        // Up to the header (past the rows above), then across to the pad's button (right of the category button).
        let header = app.descendants(matching: .any).element(matching: NSPredicate(format: "hasFocus == true"))
        for _ in 0..<30 where !(pad.exists && pad.hasFocus) && !(header.exists && header.frame.minY < 250) {
            remote.press(.up)
            usleep(400_000)
        }
        XCTAssertTrue(pad.hasFocus || moveFocus(.right, to: pad, limit: 3) || moveFocus(.left, to: pad, limit: 6), "no number pad button: \(focusedLabel)")
        remote.press(.select)
        let one = app.buttons["numberpad.1"]
        XCTAssertTrue(waitForFocus(one), "the pad did not open on 1: \(focusedLabel)")
        // within the 1.5 s the first digit waits for the second
        remote.press(.select)
        remote.press(.right)
        remote.press(.select)
        XCTAssertTrue(picture("12 · Канал 12").waitForExistence(timeout: 10), "12 did not tune to channel 12")
        snapshot("rt-83-number-tuned")
        remote.press(.up)
        XCTAssertTrue(picture("13 · Канал 13").waitForExistence(timeout: 10), "channel up did not go to 13")

        // In the player: the options row's number pad; 1 and the pause → channel 1.
        sleep(3)
        remote.press(.right)
        let number = app.buttons["live.number"]
        XCTAssertTrue(number.waitForExistence(timeout: 5), "no Channel Number control")
        XCTAssertTrue(moveFocus(.right, to: number, limit: 6), "no focus on Channel Number: \(focusedLabel)")
        remote.press(.select)
        XCTAssertTrue(waitForFocus(one), "the player's pad did not open on 1: \(focusedLabel)")
        remote.press(.select)
        XCTAssertTrue(app.descendants(matching: .any)["channel.number"].waitForExistence(timeout: 1), "no «1_» overlay")
        snapshot("rt-82-numberpad-1")
        XCTAssertTrue(picture("1 · Все фильмы").waitForExistence(timeout: 10), "1 and the pause did not tune to channel 1")
        snapshot("rt-84-player-number-after-pause")

        // 25 is the adult channel: not from All.
        sleep(2)
        remote.press(.select)
        XCTAssertTrue(moveFocus(.right, to: number, limit: 6), "no focus on Channel Number: \(focusedLabel)")
        remote.press(.select)
        XCTAssertTrue(waitForFocus(one))
        // 2 (right of 1), then 5 (under 2), within the 1.5 s
        remote.press(.right)
        remote.press(.select)
        remote.press(.down)
        remote.press(.select)
        XCTAssertTrue(app.descendants(matching: .any)["channel.number.missing"].waitForExistence(timeout: 5), "25 was not refused outside the adult category")
        XCTAssertTrue(picture("1 · Все фильмы").exists, "the adult channel was tuned from All")
        snapshot("rt-85-player-no-adult-number")
        for _ in 0..<3 where picture("1 · Все фильмы").exists {
            remote.press(.menu)
            sleep(2)
        }
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
        XCTAssertTrue(app.staticTexts[tr("Sign in with your phone")].waitForExistence(timeout: 30), "no QR sign-in screen")
        XCTAssertTrue(waitForFocus(app.buttons[tr("Sign In with the Remote")]), "focus: \(focusedLabel)")
        remote.press(.select)
        XCTAssertTrue(app.staticTexts[tr("Who's watching?")].waitForExistence(timeout: 30))
        sleep(2)
        remote.press(.right)
        remote.press(.right)
        remote.press(.select)
        XCTAssertTrue(app.buttons[tr("Details")].waitForExistence(timeout: 30))
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
        XCTAssertTrue(app.buttons[tr("Details")].waitForExistence(timeout: 30), "not back on Home")
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
        XCTAssertTrue(app.buttons[tr("Details")].waitForExistence(timeout: 30), "not back on Home")
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
        XCTAssertTrue(app.buttons[tr("Details")].waitForExistence(timeout: 30), "not back on Home: \(focusedLabel)")
        let made = mockEvents()
        XCTAssertTrue(made.contains { ($0["method"] as? String) == "POST" && ($0["path"] as? String) == "/api/me/managed" }, "no history made")
        openSeparateHistory()
        XCTAssertTrue(setting("Separate History on This Device").label.hasSuffix("Kitchen"), setting("Separate History on This Device").label)
        snapshot("rt-history-06-new-on")
    }

    /// An addon's ways on a movie page (the mock started with `--addons`, and `ANTRESOL_MOCK_ADDONS`
    /// set): the way that watches and the round button that keeps a copy, with the server's own
    /// wording. The first run has no remembered choice, so the chooser opens (a step, Menu back a
    /// step, the quality); the stream plays and reports; the second run goes straight to the player.
    /// A copy begins with its state ring, and its long-press menu cancels it.
    func testAddonWays() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["ANTRESOL_MOCK_ADDONS"] != nil,
                          "needs scripts/mock-server.py --addons and ANTRESOL_MOCK_ADDONS")
        // The third profile (Family) is an adult; the second is the kid.
        signInToMovie(profilesToTheRight: 2)
        let watch = app.buttons["Watch here"]
        let keep = app.buttons["Add to server"]
        XCTAssertTrue(watch.waitForExistence(timeout: 40), "no way button on the movie page: \(focusedLabel)")
        XCTAssertTrue(keep.exists, "no round button for the way that keeps a copy")
        XCTAssertFalse(app.buttons["Watch now"].exists, "a way for what the library lacks shows on a title it has")
        sleep(2)
        XCTAssertNotNil(mock("POST", "/mock/reset"), "no answer from the mock's second port")
        snapshot("rt-60-movie-ways")

        // The chevron beside the pill opens the menu of the ways: the one «Play» runs ticked, with its
        // hint, then «Audio & quality…».
        XCTAssertTrue(focusWayPill(), "focus: \(focusedLabel)")
        remote.press(.right)
        sleep(1)
        remote.press(.select)
        func element(_ predicate: String, _ value: String) -> XCUIElement {
            app.descendants(matching: .any).matching(NSPredicate(format: predicate, value)).firstMatch
        }
        XCTAssertTrue(element("label CONTAINS %@", "Watch here — Starts right away").waitForExistence(timeout: 10),
                      "the menu beside the pill did not open: \(focusedLabel)")
        XCTAssertTrue(element("label == %@", "Audio & quality…").exists, "no «Audio & quality…» in the menu")
        snapshot("rt-60b-way-menu")
        remote.press(.menu)
        XCTAssertTrue(watch.waitForExistence(timeout: 10), "the menu did not close")
        sleep(1)

        // First run: nothing remembered, so the chooser opens on the first step.
        XCTAssertTrue(focusWayPill(), "focus: \(focusedLabel)")
        remote.press(.select)
        let mirror = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Mirror one")).firstMatch
        XCTAssertTrue(app.staticTexts["Source"].waitForExistence(timeout: 20), "the chooser did not open")
        XCTAssertTrue(waitForFocus(mirror, seconds: 10), "focus did not start on the last choice: \(focusedLabel)")
        snapshot("rt-61-chooser-first-step")
        remote.press(.select)
        XCTAssertTrue(app.staticTexts["Quality"].waitForExistence(timeout: 20), "no second step")
        let best = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "1080p")).firstMatch
        XCTAssertTrue(waitForFocus(best, seconds: 10), "focus: \(focusedLabel)")
        snapshot("rt-62-chooser-second-step")
        // Menu goes back a step, not out of the chooser.
        remote.press(.menu)
        XCTAssertTrue(app.staticTexts["Source"].waitForExistence(timeout: 10), "Menu did not go back a step")
        remote.press(.select)
        XCTAssertTrue(app.staticTexts["Quality"].waitForExistence(timeout: 20))
        XCTAssertTrue(waitForFocus(best, seconds: 10), "focus: \(focusedLabel)")
        remote.press(.select)

        // The stream plays, reports and is released.
        XCTAssertTrue(waitForEvent(timeout: 40) { $0["path"] as? String == "/api/addons/alpha/x/media/s1/clip.mp4" },
                      "the addon's stream was not requested")
        snapshot("rt-63-way-playing")
        XCTAssertTrue(waitForEvent(timeout: 30) { $0["method"] as? String == "PUT" && $0["path"] as? String == "/api/addons/alpha/x/app/progress" },
                      "no progress written to the addon")
        XCTAssertTrue(closeWayPlayer(session: "s1"), "Menu did not close the player and release the addon's session")
        XCTAssertTrue(watch.waitForExistence(timeout: 10), "not back on the movie page")
        let runs = mockEvents().filter { $0["path"] as? String == "/api/addons/alpha/x/app/run" }
        XCTAssertEqual(runs.count, 2, "the quick run and the one with the choice: \(runs)")
        XCTAssertTrue((runs.first?["body"] as? String)?.contains("\"quick\":true") == true, "the first run was not a quick one: \(String(describing: runs.first))")
        XCTAssertTrue((runs.last?["body"] as? String)?.contains("\"ref\":\"mirror-1:1080\"") == true, "the second run did not carry the choice: \(String(describing: runs.last))")

        // Second run: remembered, so the player opens at once.
        sleep(2)
        XCTAssertTrue(focusWayPill(), "focus: \(focusedLabel)")
        remote.press(.select)
        XCTAssertTrue(waitForEvent(timeout: 40) { $0["path"] as? String == "/api/addons/alpha/x/media/s2/clip.mp4" },
                      "the remembered choice did not play at once")
        XCTAssertFalse(app.staticTexts["Source"].exists, "the chooser opened for a remembered choice")
        XCTAssertTrue(closeWayPlayer(session: "s2"), "Menu did not close the player and release the addon's session")
        XCTAssertTrue(watch.waitForExistence(timeout: 10), "not back on the movie page")

        // A copy: the chooser (quality, then releases), a notice, and the ring.
        sleep(2)
        XCTAssertTrue(focusRound("Add to server"), "focus: \(focusedLabel)")
        remote.press(.select)
        XCTAssertTrue(app.staticTexts["Quality"].waitForExistence(timeout: 20), "no chooser for the copy")
        snapshot("rt-64-copy-quality")
        remote.press(.select)
        XCTAssertTrue(app.staticTexts["Releases"].waitForExistence(timeout: 20), "no releases step")
        snapshot("rt-65-copy-releases")
        remote.press(.select)
        XCTAssertTrue(keep.waitForExistence(timeout: 20), "back on the movie page")
        XCTAssertTrue(app.staticTexts["Copy started"].waitForExistence(timeout: 10), "no notice of the copy")
        snapshot("rt-66-copy-started")
        sleep(3)
        XCTAssertTrue(focusRound("Add to server"), "focus: \(focusedLabel)")
        // Asked every 5 s while it is active.
        sleep(12)
        let states = mockEvents().filter { ($0["path"] as? String)?.hasSuffix("/beta/x/app/state") == true }
        XCTAssertGreaterThanOrEqual(states.count, 3, "the state was not polled: \(states.count)")
        snapshot("rt-67-copy-ring")
        remote.press(.select, forDuration: 1.5)
        // The menu's entries are not all buttons to the test: any element labelled so.
        let cancel = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Cancel")).firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 10), "no Cancel in the long-press menu")
        snapshot("rt-68-copy-menu")
        remote.press(.select)
        XCTAssertTrue(waitForEvent(timeout: 10) { $0["method"] as? String == "POST" && $0["path"] as? String == "/api/addons/beta/x/app/cancel" },
                      "the copy was not cancelled")
    }

    /// Search finds what the library lacks (the mock with `--addons`; both addons answer a search with
    /// titles of their own, whatever the text): their shelves come after the library's, each under the
    /// heading its addon names. A title the library lacks opens its own page, with the ways the addons
    /// offer it and a show's seasons; Menu comes back to the card it was opened from. A title the library
    /// has opens the library's page.
    func testSearchOpensATitleTheLibraryLacks() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["ANTRESOL_MOCK_ADDONS"] != nil,
                          "needs scripts/mock-server.py --addons and ANTRESOL_MOCK_ADDONS")
        // A press after a failed step would land on whatever has focus: stop at the first failure.
        continueAfterFailure = false
        // The third profile (Family) is an adult; the kid is offered no ways.
        signInToMovie(profilesToTheRight: 2, openingMovie: false)
        XCTAssertTrue(app.buttons[tr("Details")].waitForExistence(timeout: 40), "not signed in: \(focusedLabel)")
        sleep(2)
        XCTAssertTrue(openSection(tr("Search"), showing: app.searchFields.firstMatch), "no Search tab: \(focusedLabel)")
        sleep(2)
        app.searchFields.firstMatch.typeText("far")

        func card(_ title: String) -> XCUIElement {
            app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", title)).firstMatch
        }
        // The addons' headings, after the library's shelves.
        XCTAssertTrue(app.staticTexts["Find and add"].waitForExistence(timeout: 30), "no shelf of the addon that adds")
        XCTAssertTrue(app.staticTexts["Find and watch"].exists, "no shelf of the addon that watches")
        let far = card("Far Show")
        XCTAssertTrue(far.exists, "the addon's title is not on its shelf")
        sleep(2)
        snapshot("rt-89-search-results")
        // Down from the keyboard to the shelf, through the library's.
        XCTAssertTrue(moveFocus(.down, to: far, limit: 14), "focus cannot reach the addon's title: \(focusedLabel)")
        sleep(2)
        snapshot("rt-90-search-addon-shelf")

        // A show the library lacks: its page, the addons' ways, the seasons.
        remote.press(.select)
        let play = app.buttons["way-play"]
        let keep = app.buttons["Add to server"]
        XCTAssertTrue(play.waitForExistence(timeout: 30), "no title page with a way to watch: \(focusedLabel)")
        XCTAssertTrue(app.buttons["way-menu"].exists, "no menu of the ways beside the pill")
        XCTAssertTrue(keep.exists, "no round button for the way that keeps a copy")
        XCTAssertTrue(app.staticTexts["Far Show"].exists, "no title on the page")
        XCTAssertTrue(waitForFocus(play, seconds: 8), "focus did not start on the pill: \(focusedLabel)")
        XCTAssertTrue(app.staticTexts["A show the library lacks."].waitForExistence(timeout: 10), "no overview")
        sleep(3)
        snapshot("rt-91-title-page-show")
        // Down to the seasons and back up: the remote reaches every row.
        remote.press(.down)
        sleep(1)
        XCTAssertFalse(play.hasFocus, "focus did not leave the buttons for the seasons: \(focusedLabel)")
        snapshot("rt-92-title-page-seasons")
        remote.press(.up)
        XCTAssertTrue(waitForFocus(play), "focus did not come back to the buttons: \(focusedLabel)")
        remote.press(.menu)
        XCTAssertTrue(waitForFocus(far, seconds: 10), "Menu did not come back to the card: \(focusedLabel)")
        sleep(2)
        snapshot("rt-93-back-on-the-card")

        // A film the library lacks, from the other addon's shelf: the ways of both addons in the menu.
        let film = card("Sample Film")
        XCTAssertTrue(moveFocus(.up, to: film, limit: 3), "focus cannot reach the film: \(focusedLabel)")
        remote.press(.select)
        XCTAssertTrue(play.waitForExistence(timeout: 30), "no title page for the film: \(focusedLabel)")
        XCTAssertTrue(waitForFocus(play, seconds: 8), "focus did not start on the pill: \(focusedLabel)")
        remote.press(.right)
        sleep(1)
        remote.press(.select)
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "Watch here")).firstMatch
            .waitForExistence(timeout: 10), "the menu of the ways did not open: \(focusedLabel)")
        snapshot("rt-94-title-page-film-ways")
        remote.press(.menu)
        sleep(1)
        remote.press(.menu)
        XCTAssertTrue(waitForFocus(film, seconds: 10), "Menu did not come back to the film's card: \(focusedLabel)")

        // A title the library has (next to the film on the same shelf) opens the library's own page: it
        // has its own buttons, and no pill of the addons for what the library lacks.
        remote.press(.right)
        sleep(1)
        XCTAssertTrue(focusedLabel.contains("Test Show"), "focus is not on the title the library has: \(focusedLabel)")
        remote.press(.select)
        XCTAssertTrue(app.buttons[tr("Mark as Watched")].waitForExistence(timeout: 30), "the library's title did not open its own page: \(focusedLabel)")
        sleep(2)
        snapshot("rt-95-library-title-page")
    }

    /// A kid's profile is offered no ways, and the app does not even ask the addons for them.
    func testNoAddonWaysForAKid() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["ANTRESOL_MOCK_ADDONS"] != nil,
                          "needs scripts/mock-server.py --addons and ANTRESOL_MOCK_ADDONS")
        mock("POST", "/mock/reset")
        signInToMovie(profilesToTheRight: 1)
        XCTAssertTrue(app.buttons[tr("Mark as Watched")].waitForExistence(timeout: 40), "no movie page: \(focusedLabel)")
        sleep(3)
        XCTAssertFalse(app.buttons["Watch here"].exists, "a kid's page offers a way")
        XCTAssertFalse(app.buttons["Add to server"].exists, "a kid's page offers a way that keeps a copy")
        snapshot("rt-69-movie-without-ways-for-a-kid")
        let asked = mockEvents().filter { ($0["path"] as? String)?.hasPrefix("/api/addons") == true }
        XCTAssertTrue(asked.isEmpty, "the addons were asked for a kid: \(asked)")
    }

    // MARK: What the iPhone review found, as it shows on the Apple TV

    /// The chooser of a way (the mock with `--addons`): every row's badges are one height, a subtitles badge with no
    /// language shows the word beside its icon, and a step's note is the list's footer, under the rows.
    func testChooserLayout() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["ANTRESOL_MOCK_ADDONS"] != nil,
                          "needs scripts/mock-server.py --addons and ANTRESOL_MOCK_ADDONS")
        // A press after a failed step would land on whatever has focus: stop at the first failure.
        continueAfterFailure = false
        signInToMovie(profilesToTheRight: 2)
        XCTAssertTrue(app.buttons["Watch here"].waitForExistence(timeout: 40), "no way button on the movie page: \(focusedLabel)")
        sleep(2)
        XCTAssertNotNil(mock("POST", "/mock/reset"), "no answer from the mock's second port")
        snapshot("owner-00-movie-actions")
        // The primary pill's title stays on one line (a wrapped one would make the pill taller than its 76 pt).
        let primary = app.buttons[tr("Resume")]
        XCTAssertTrue(primary.exists && primary.frame.height < 100, "the Resume pill is not one line: \(primary.frame)")
        XCTAssertTrue(focusWayPill(), "focus: \(focusedLabel)")
        remote.press(.select)
        XCTAssertTrue(app.staticTexts["Source"].waitForExistence(timeout: 20), "the chooser did not open")
        sleep(2)
        snapshot("owner-01-chooser-source")
        let rows = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Mirror"))
        XCTAssertEqual(rows.count, 4, "the chooser's rows: \(rows.allElementsBoundByIndex.map(\.label))")
        remote.press(.down)
        remote.press(.down)
        sleep(2)
        snapshot("owner-02-chooser-badges-focused")
        remote.press(.select)
        XCTAssertTrue(app.staticTexts["Quality"].waitForExistence(timeout: 20), "no second step")
        sleep(2)
        snapshot("owner-03-chooser-quality")
        let note = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Picks the best release")).firstMatch
        XCTAssertTrue(note.exists, "no note on the step")
        let lastRow = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "1080p")).firstMatch
        XCTAssertGreaterThan(note.frame.minY, lastRow.frame.maxY - 1, "the note is not under the list: \(note.frame) \(lastRow.frame)")
        let title = app.staticTexts["Quality"]
        XCTAssertLessThan(lastRow.frame.minY - title.frame.maxY, 200, "a gap between the title and the list: \(title.frame) \(lastRow.frame)")
    }

    /// Everything of the profile's settings is on one page, About last.
    func testSettingsOnOnePage() {
        // A press after a failed step would land on whatever has focus: stop at the first failure.
        continueAfterFailure = false
        signInToMovie(profilesToTheRight: 2, openingMovie: false)
        XCTAssertTrue(app.buttons[tr("Details")].waitForExistence(timeout: 40), "no Home: \(focusedLabel)")
        sleep(3)
        XCTAssertTrue(openSection("Family", prefix: true, showing: app.buttons[tr("Switch Profile")]), "no Settings: \(focusedLabel)")
        sleep(2)
        snapshot("owner-10-settings-top")
        let language = setting(tr("Interface Language"))
        remote.press(.down)
        sleep(1)
        moveFocus(.right, to: setting(tr("Video Quality")), limit: 3)
        XCTAssertTrue(moveFocus(.down, to: language, limit: 10), "no Interface Language row: \(focusedLabel)")
        sleep(1)
        snapshot("owner-11-settings-language")
        // The section's title is drawn in capitals.
        let about = app.staticTexts.matching(NSPredicate(format: "label ==[c] %@", tr("About This App"))).firstMatch
        for _ in 0..<6 { remote.press(.down); usleep(500_000) }
        sleep(2)
        XCTAssertTrue(about.exists, "no About section: \(focusedLabel)")
        snapshot("owner-12-settings-bottom")
    }

    /// A poster opens its page, Menu closes it, and focus comes back to the poster; then the grid scrolls on.
    func testPosterOpensAndClosesWithFocusBack() {
        // A press after a failed step would land on whatever has focus: stop at the first failure.
        continueAfterFailure = false
        signInAsKid()
        XCTAssertTrue(openSection(tr("Movies"), showing: app.buttons[tr("Recently Added")]), "no Movies: \(focusedLabel)")
        sleep(2)
        remote.press(.down)
        sleep(1)
        let tile = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Big Buck Demo")).firstMatch
        XCTAssertTrue(moveFocus(.left, to: tile, limit: 6), "focus: \(focusedLabel)")
        sleep(1)
        snapshot("owner-20-poster-focused")
        remote.press(.select)
        sleep(3)
        snapshot("owner-21-page")
        XCTAssertTrue(app.buttons[tr("Play")].exists || app.buttons[tr("Resume")].exists, "the page did not open: \(focusedLabel)")
        remote.press(.menu)
        sleep(3)
        XCTAssertTrue(tile.exists && tile.hasFocus, "focus did not come back to the tile: \(focusedLabel)")
        snapshot("owner-22-back-on-poster")
        // Scrolled on: the title and the sort pill stay above the grid, and rows going up fade out under them.
        for _ in 0..<3 {
            remote.press(.down)
            sleep(1)
        }
        sleep(1)
        snapshot("owner-23-library-scrolled")
    }

    /// The round buttons' glyphs against the circle's middle: the hero's, the live player's options row and its number pad.
    /// The frames go in an attachment, to measure the screenshots against.
    func testRoundButtonGlyphs() {
        // A press after a failed step would land on whatever has focus: stop at the first failure.
        continueAfterFailure = false
        signInAsKid()
        sleep(2)
        attachFrames("owner-30-hero-frames", ["Watchlist", "Details", "Next"].map { ($0, app.buttons[tr($0)]) })
        snapshot("owner-30-hero")
        XCTAssertTrue(openTV(), "no TV tab: \(focusedLabel)")
        let row = channelRow("Комедии")
        XCTAssertTrue(waitForFocus(row), "the list did not open on the last channel: \(focusedLabel)")
        remote.press(.select)
        XCTAssertTrue(app.staticTexts[tr("Switch Channel")].waitForNonExistence(timeout: 40), "channel 2 did not start playing")
        remote.press(.right)
        let audio = app.buttons["live.audio"]
        XCTAssertTrue(audio.waitForExistence(timeout: 5), "no Audio control")
        XCTAssertTrue(waitForFocus(audio), "the options row did not take focus on Audio: \(focusedLabel)")
        sleep(2)
        attachFrames("owner-31-live-frames", ["audio", "subtitles", "quality", "favorite", "previous", "number", "channels"].map { ($0, app.buttons["live.\($0)"]) })
        snapshot("owner-31-live-options")
        let number = app.buttons["live.number"]
        XCTAssertTrue(moveFocus(.right, to: number, limit: 6), "no focus on Channel Number: \(focusedLabel)")
        remote.press(.select)
        XCTAssertTrue(app.buttons["numberpad.1"].waitForExistence(timeout: 5), "no number pad")
        sleep(2)
        attachFrames("owner-32-pad-frames", ["delete", "ok", "1", "5"].map { ($0, app.buttons["numberpad.\($0)"]) })
        snapshot("owner-32-number-pad")
    }

    /// The frames (points) of `elements` as a text attachment.
    private func attachFrames(_ name: String, _ elements: [(String, XCUIElement)]) {
        let text = elements.map { "\($0.0)\t\($0.1.exists ? "\($0.1.frame)" : "missing")" }.joined(separator: "\n")
        let attachment = XCTAttachment(string: text)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// The app's own string for `key` in the language the run is in (the key itself in English).
    private func tr(_ key: String) -> String {
        guard language != "en" else { return key }
        let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("AntresolTV/Resources/\(language).lproj/Localizable.strings").path
        return (NSDictionary(contentsOfFile: path) as? [String: String])?[key] ?? key
    }

    /// Fresh session on the mock's second port, the profile `profilesToTheRight` places after the
    /// first one, and the movie's page (a link, so it opens as soon as the profile is in).
    private func signInToMovie(profilesToTheRight: Int, openingMovie: Bool = true) {
        if openingMovie { app.launchArguments += ["-AntresolOpenURL", "antresol://item/19"] }
        launch(server: pairingServer)
        XCTAssertTrue(app.staticTexts[tr("Sign in with your phone")].waitForExistence(timeout: 30), "no QR sign-in screen")
        XCTAssertTrue(waitForFocus(app.buttons[tr("Sign In with the Remote")]), "focus: \(focusedLabel)")
        remote.press(.select)
        XCTAssertTrue(app.staticTexts[tr("Who's watching?")].waitForExistence(timeout: 30))
        sleep(2)
        for _ in 0..<profilesToTheRight { remote.press(.right) }
        remote.press(.select)
    }

    /// Puts focus on the way's pill, the third of the movie page's row (Resume, Restart, the way). The
    /// pill has a long-press menu, and a focused one is not reported as focused to the test: it is
    /// reached by its place, from Resume.
    private func focusWayPill() -> Bool {
        let resume = app.buttons[tr("Resume")]
        for _ in 0..<8 where !(resume.exists && resume.hasFocus) {
            remote.press(.left)
            sleep(1)
            if focusedLabel == "none" || focusedLabel.contains("Home") { remote.press(.right); sleep(1) }
        }
        guard resume.exists && resume.hasFocus else { return false }
        remote.press(.right)
        sleep(1)
        remote.press(.right)
        sleep(1)
        return true
    }

    /// Puts focus on a round button of the row by its label, whichever way from the pill it is.
    private func focusRound(_ label: String) -> Bool {
        func focused() -> Bool { app.buttons.allElementsBoundByIndex.contains { $0.label == label && $0.hasFocus } }
        for direction in [XCUIRemote.Button.right, .left, .right] {
            for _ in 0..<6 {
                if focused() { return true }
                remote.press(direction)
                sleep(1)
            }
        }
        return focused()
    }

    /// Menu until the addon's session is released (the player closed): the session's `DELETE`.
    private func closeWayPlayer(session: String) -> Bool {
        for _ in 0..<4 {
            remote.press(.menu)
            if waitForEvent(timeout: 6, { $0["method"] as? String == "DELETE" && $0["path"] as? String == "/api/addons/alpha/x/app/play/\(session)" }) {
                return true
            }
        }
        return false
    }

    /// Polls the mock's record until an event satisfies `match`.
    private func waitForEvent(timeout: Int, _ match: ([String: Any]) -> Bool) -> Bool {
        let started = Date()
        while Date().timeIntervalSince(started) < Double(timeout) {
            if mockEvents().contains(where: match) { return true }
            sleep(1)
        }
        return false
    }

    /// Fresh session on the mock's second port (QR sign-in, the mock's test hooks), then
    /// the passwordless second profile through the profile picker.
    private func signInOnSecondPort() {
        launch(server: pairingServer)
        XCTAssertTrue(app.staticTexts[tr("Sign in with your phone")].waitForExistence(timeout: 30), "no QR sign-in screen")
        XCTAssertTrue(waitForFocus(app.buttons[tr("Sign In with the Remote")]), "focus: \(focusedLabel)")
        remote.press(.select)
        XCTAssertTrue(app.staticTexts[tr("Who's watching?")].waitForExistence(timeout: 30))
        sleep(2)
        remote.press(.right)
        remote.press(.select)
        XCTAssertTrue(app.buttons[tr("Details")].waitForExistence(timeout: 30))
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

    /// A channel's row in the TV list (not a category of the same name in the category list).
    private func channelRow(_ text: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@ AND NOT (identifier BEGINSWITH %@)", text, "tv.category.")).firstMatch
    }

    /// Focuses the TV page's category button: up from the list to the header (past the rows
    /// above), then across to it.
    private func focusCategoryButton() -> Bool {
        let button = app.buttons["tv.categories"]
        guard button.waitForExistence(timeout: 10) else { return false }
        let focused = app.descendants(matching: .any).element(matching: NSPredicate(format: "hasFocus == true"))
        for _ in 0..<30 where !button.hasFocus && !(focused.exists && focused.frame.minY < 260) {
            remote.press(.up)
            usleep(400_000)
        }
        return button.hasFocus || moveFocus(.right, to: button, limit: 3) || moveFocus(.left, to: button, limit: 3)
    }

    /// The live player's picture, labelled with the channel on screen.
    private func picture(_ label: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label)).firstMatch
    }

    private func launch(server: String) {
        app.launchArguments += ["-AntresolResetSession", "YES", "-AntresolServerURL", server, "-AppleLanguages", "(\(language))"]
        // the TV tab as a first visit has it (a test that left it on the guide does not leak)
        if !app.launchArguments.contains("-tv.mode") { app.launchArguments += ["-tv.mode", "channels", "-tv.filter", "all"] }
        app.launch()
    }

    /// Fresh session, then the passwordless second profile.
    private func signInAsKid() {
        launch(server: server)
        XCTAssertTrue(app.staticTexts[tr("Who's watching?")].waitForExistence(timeout: 30))
        sleep(2)
        remote.press(.right)
        remote.press(.select)
        XCTAssertTrue(app.buttons[tr("Details")].waitForExistence(timeout: 30))
        sleep(3)
    }

    /// Opens the TV tab from the sidebar and waits for the list.
    private func openTV() -> Bool {
        openSection(tr("TV"), showing: app.buttons[tr("Guide")])
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
        XCTAssertTrue(openSection("Family", prefix: true, showing: app.buttons[tr("Switch Profile")]), "no Settings: \(focusedLabel)")
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
