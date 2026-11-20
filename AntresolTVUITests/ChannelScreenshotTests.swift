import XCTest

/// The TV tab and the live player against a real server with channels (the mock server
/// has no live streams). Skipped unless `CHANNELS_SERVER` (the server's address),
/// `CHANNELS_PROFILE` (a profile's name) and `CHANNELS_PASSWORD` are set, as
/// `TEST_RUNNER_CHANNELS_…` for `xcodebuild test`; `CHANNELS_SHOTS_DIR` also gets the PNGs.
/// Runs in Russian; `CHANNELS_LANGUAGE=en` runs it in English.
final class ChannelScreenshotTests: XCTestCase {
    private let remote = XCUIRemote.shared
    private let app = XCUIApplication()
    private var dir = ""

    override func setUpWithError() throws {
        let env = ProcessInfo.processInfo.environment
        guard let server = env["CHANNELS_SERVER"], !server.isEmpty,
              let profile = env["CHANNELS_PROFILE"], !profile.isEmpty
        else { throw XCTSkip("CHANNELS_SERVER and CHANNELS_PROFILE not set") }
        continueAfterFailure = true
        dir = env["CHANNELS_SHOTS_DIR"] ?? ""
        app.launchArguments += [
            "-AntresolResetSession", "YES", "-AntresolServerURL", server,
            // Russian through the app's own language setting: the system stays English, so
            // the keyboard types the Latin password.
            "-app.language", env["CHANNELS_LANGUAGE"] ?? "ru", "-AppleLanguages", "(en)",
            "-AppleLocale", env["CHANNELS_LANGUAGE"] == "en" ? "en_GB" : "ru_RU",
        ]
        self.profile = profile
        password = env["CHANNELS_PASSWORD"] ?? ""
    }

    private var profile = ""
    private var password = ""

    /// The device in English, the profile's interface language Russian
    /// (`GET /api/me/ui-language` effective "ru"): after sign-in everything is Russian,
    /// with 24-hour times. Sign-in runs in English (the device's language).
    func testInterfaceLanguageFromProfile() {
        let server = ProcessInfo.processInfo.environment["CHANNELS_SERVER"] ?? ""
        app.launchArguments = ["-AntresolResetSession", "YES", "-AntresolServerURL", server, "-app.language", "system", "-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-tv.mode", "channels", "-tv.filter", "all"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Who's watching?"].waitForExistence(timeout: 40), "the picker is in the device's English")
        shot("r4-50-picker-device-english", delay: 1)
        let entry = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", profile)).firstMatch
        XCTAssertTrue(entry.waitForExistence(timeout: 10))
        moveFocus(.right, to: entry, limit: 8)
        remote.press(.select)
        let field = app.secureTextFields.firstMatch
        if field.waitForExistence(timeout: 10) {
            sleep(1)
            if !field.hasFocus { moveFocus(.down, to: field, limit: 4) }
            remote.press(.select)
            sleep(2)
            app.typeText(password)
            sleep(1)
            remote.press(.menu)
            sleep(2)
            moveFocus(.down, to: app.buttons["Sign In"], limit: 4)
            remote.press(.select)
        }
        XCTAssertTrue(app.buttons["Подробнее"].waitForExistence(timeout: 40), "not Russian after sign-in")
        shot("r4-51-home-profile-russian", delay: 3)
        XCTAssertTrue(openSection("ТВ", showing: app.buttons["Каналы"]) || openSection("ТВ", showing: app.buttons["Каналы"]), "no ТВ tab")
        shot("r4-52-tv-profile-russian", delay: 4)
        remote.press(.select, forDuration: 1.6)
        sleep(1)
        remote.press(.menu)
        sleep(1)
        remote.press(.select)
        shot("r4-53-player-profile-russian", delay: 10)
        remote.press(.menu)
        sleep(2)
    }

    /// Launches with the TV tab's view and filter set (`tv.mode`, `tv.filter`) and signs in.
    private func launch(mode: String = "channels", filter: String = "all") {
        app.launchArguments += ["-tv.mode", mode, "-tv.filter", filter]
        app.launch()
        signIn(profile, password: password)
    }

    /// The channel list: focus starts on the last channel; a long press offers the star.
    func testList() {
        launch()
        XCTAssertTrue(openTV(), "no TV tab: \(focusedLabel)")
        shot("r3-01-list", delay: 4)
        remote.press(.down)
        shot("r3-02-list-moved", delay: 2)
        remote.press(.select, forDuration: 1.6)
        shot("r3-03-list-context", delay: 2)
        remote.press(.menu)
        sleep(1)
    }

    /// The profile picker with the profiles' photos (the letter for one without), the
    /// category button and its list (the server's AI topics, sources and groups with
    /// headings and counts), the list narrowed to a topic, and the sidebar's avatar.
    func testCategories() {
        app.launchArguments += ["-tv.mode", "channels", "-tv.filter", "all"]
        app.launch()
        XCTAssertTrue(app.staticTexts[t("Who's watching?", "Кто смотрит?")].waitForExistence(timeout: 40), "no profile picker")
        shot("c-01-picker", delay: 3)
        signIn(profile, password: password)
        XCTAssertTrue(openTV(), "no TV tab: \(focusedLabel)")
        shot("c-02-list", delay: 4)
        let button = app.buttons["tv.categories"]
        XCTAssertTrue(focusByGeometry(button), "no category button: \(focusedLabel)")
        shot("c-03-button", delay: 1)
        remote.press(.select)
        shot("c-04-categories", delay: 2)
        // From the current one (All) past Favourites to the first topic, and choose it.
        remote.press(.down)
        sleep(1)
        remote.press(.down)
        shot("c-05-categories-topic", delay: 1)
        remote.press(.select)
        shot("c-06-topic-list", delay: 3)
        XCTAssertFalse(button.hasFocus, "the chosen category's channels take focus, not the button")
        // The sidebar, with the profile's photo at its top.
        for _ in 0..<3 {
            remote.press(.left)
            sleep(1)
        }
        shot("c-07-sidebar", delay: 2)
        // The profile page: its photo, large.
        // (its sidebar entry is «<name>, Profile and Settings», the sidebar's last)
        for _ in 0..<4 where !focusedLabel.hasPrefix(profile) {
            remote.press(.down)
            sleep(1)
        }
        remote.press(.select)
        XCTAssertTrue(app.buttons[t("Switch Profile", "Сменить профиль")].waitForExistence(timeout: 20), "no profile page: \(focusedLabel)")
        shot("c-08-settings", delay: 3)
    }

    /// The Favourites filter.
    func testFavourites() {
        launch(filter: "favorites")
        XCTAssertTrue(openTV(), "no TV tab: \(focusedLabel)")
        shot("r3-04-favourites", delay: 4)
    }

    /// The guide: the cursor moves keeping the time, a programme opens, «Смотреть» tunes in.
    func testGuide() {
        launch(mode: "guide")
        XCTAssertTrue(openTV(), "no TV tab: \(focusedLabel)")
        sleep(3)
        shot("r3-05-guide-header", delay: 1)
        // Down from the header into the grid: the last channel's programme on air.
        remote.press(.down)
        sleep(1)
        remote.press(.down)
        sleep(1)
        shot("r3-06-guide", delay: 2)
        // The programme on air: details with «Смотреть».
        remote.press(.select)
        shot("r3-09b-programme-on-air", delay: 3)
        remote.press(.menu)
        sleep(2)
        remote.press(.down)
        sleep(1)
        remote.press(.right)
        shot("r3-07-guide-moved", delay: 2)
        remote.press(.right)
        sleep(1)
        remote.press(.down)
        shot("r3-08-guide-down", delay: 2)
        for _ in 0..<4 {
            remote.press(.down)
            sleep(1)
        }
        shot("r3-08b-guide-scrolled", delay: 2)
        remote.press(.left)
        sleep(1)
        remote.press(.left)
        sleep(1)
        remote.press(.select)
        shot("r3-09-programme", delay: 3)
        remote.press(.menu)
        sleep(2)
        // Back to the programme on air of the first row: «Смотреть» tunes in.
        for _ in 0..<6 {
            remote.press(.up)
            sleep(1)
        }
        remote.press(.down)
        sleep(2)
        remote.press(.select)
        sleep(3)
        let watch = app.buttons[t("Watch", "Смотреть")]
        if watch.waitForExistence(timeout: 3) {
            focusByGeometry(watch)
            remote.press(.select)
            shot("r3-10-guide-watch", delay: 10)
            remote.press(.menu)
            sleep(3)
        }
    }

    /// The player: banner, options row, audio and subtitle lists, star, zap and the
    /// mini-guide.
    func testLivePlayer() {
        launch()
        XCTAssertTrue(openTV(), "no TV tab: \(focusedLabel)")
        remote.press(.select)
        shot("r3-20-player-starting", delay: 1)
        shot("r3-21-player-banner", delay: 9)
        shot("r3-22-player-clean", delay: 6)
        // Right: the options row, focus on Audio (Select opens the channel list).
        remote.press(.right)
        shot("r3-23-player-options", delay: 2)
        let audio = app.buttons["live.audio"]
        if audio.exists {
            moveFocus(.left, to: audio, limit: 4)
            remote.press(.select)
            shot("r3-24-player-audio", delay: 2)
            // Another voice: the second entry.
            remote.press(.down)
            sleep(1)
            remote.press(.select)
            shot("r3-24b-player-audio-picked", delay: 4)
        }
        let subtitles = app.buttons["live.subtitles"]
        if subtitles.exists {
            moveFocus(.right, to: subtitles, limit: 4)
            remote.press(.select)
            shot("r3-25-player-subtitles", delay: 2)
            remote.press(.down)
            sleep(1)
            remote.press(.select)
            shot("r3-25b-player-subtitles-on", delay: 6)
        }
        // The star.
        let star = app.buttons["live.favorite"]
        if moveFocus(.right, to: star, limit: 4) {
            remote.press(.select)
            shot("r3-25c-player-starred", delay: 2)
        }
        remote.press(.menu)
        sleep(2)
        // Zap up and down: the held picture and the banner.
        remote.press(.up)
        shot("r3-26-zap-held", delay: 0)
        shot("r3-27-zapped", delay: 9)
        remote.press(.down)
        sleep(9)
        // The channel list (from the options row).
        remote.press(.right)
        shot("r3-27b-options-again", delay: 2)
        let channels = app.buttons["live.channels"]
        if moveFocus(.right, to: channels, limit: 5) {
            remote.press(.select)
            shot("r3-28-mini-guide", delay: 2)
            remote.press(.down)
            shot("r3-29-mini-guide-moved", delay: 1)
            // Left: the category column beside the list
            remote.press(.left)
            shot("r3-29b-list-categories", delay: 2)
            remote.press(.right)
            sleep(1)
            remote.press(.menu)
            sleep(2)
        }
        remote.press(.menu)
        sleep(3)
    }

    /// External channels (`CHANNELS_EXT=1`; make «Demo Bipbop Advanced», the first external
    /// channel, the profile's last channel first, followed in number by «Demo Mux», «Demo
    /// Bipbop», a channel that never opens and one whose primary fails and fallback plays):
    /// the list and the guide with them, the player on each, the stream's own audio and
    /// subtitles, the failure and Up out of it onto the fallback.
    func testExternalChannels() throws {
        guard ProcessInfo.processInfo.environment["CHANNELS_EXT"] == "1" else { throw XCTSkip("CHANNELS_EXT not set") }
        launch()
        XCTAssertTrue(openTV(), "no TV tab: \(focusedLabel)")
        shot("r6-70-list-external", delay: 5)
        remote.press(.select)
        shot("r6-71-player-bipbop-advanced", delay: 12)
        // the stream's own subtitles
        remote.press(.select)
        sleep(2)
        let subtitles = app.buttons["live.subtitles"]
        if moveFocus(.right, to: subtitles, limit: 4) {
            remote.press(.select)
            shot("r6-72-subtitles-from-stream", delay: 2)
            remote.press(.down)
            sleep(1)
            remote.press(.select)
            shot("r6-73-subtitles-picked", delay: 6)
        } else {
            XCTFail("no Subtitles control on «Demo Bipbop Advanced»")
        }
        let audio = app.buttons["live.audio"]
        if audio.exists, moveFocus(.left, to: audio, limit: 4) {
            remote.press(.select)
            shot("r6-74-audio-from-stream", delay: 2)
            remote.press(.menu)
            sleep(1)
        }
        remote.press(.menu)
        sleep(2)
        remote.press(.up)
        shot("r6-75-player-mux", delay: 12)
        remote.press(.up)
        shot("r6-76-player-bipbop", delay: 12)
        remote.press(.up)
        let failed = app.staticTexts[t("This channel won’t open right now", "Канал сейчас не открывается")]
        XCTAssertTrue(failed.waitForExistence(timeout: 45), "no failure message")
        shot("r6-77-failed", delay: 1)
        remote.press(.up)
        sleep(15)
        XCTAssertFalse(failed.exists, "the next channel did not open on its fallback")
        shot("r6-78-fallback-playing", delay: 0)
        remote.press(.menu)
        sleep(3)
    }

    /// Pause on live (`CHANNELS_PAUSE=1`; the profile's last channel an own channel):
    /// Play/Pause pauses, 13 s later the banner says «В эфир» instead of LIVE; playing on
    /// stays behind; the options row's first button, «В эфир», takes it back to the edge.
    func testPauseBehindLive() throws {
        guard ProcessInfo.processInfo.environment["CHANNELS_PAUSE"] == "1" else { throw XCTSkip("CHANNELS_PAUSE not set") }
        launch()
        XCTAssertTrue(openTV(), "no TV tab: \(focusedLabel)")
        remote.press(.select)
        sleep(12)
        remote.press(.playPause)
        shot("r6-81-paused", delay: 2)
        sleep(13)
        let behind = app.descendants(matching: .any)["live.behind"]
        XCTAssertTrue(behind.waitForExistence(timeout: 5), "no «В эфир» after a pause")
        shot("r6-82-behind-live-paused", delay: 0)
        remote.press(.playPause)
        sleep(3)
        XCTAssertTrue(behind.exists, "«В эфир» gone after a short pause")
        shot("r6-83-behind-live", delay: 0)
        remote.press(.select)
        sleep(2)
        let goLive = app.buttons["live.goLive"]
        XCTAssertTrue(goLive.waitForExistence(timeout: 3), "no «В эфир» in the options row")
        shot("r6-84-options-go-live", delay: 0)
        if goLive.exists { moveFocus(.left, to: goLive, limit: 5); remote.press(.select) }
        sleep(4)
        XCTAssertFalse(behind.exists, "still behind after «В эфир»")
        shot("r6-85-live-again", delay: 0)
        remote.press(.menu)
        sleep(2)
    }

    /// The guide with the external rows (the last channel's row first in view) and an
    /// external programme's details (no item page behind it).
    func testExternalGuide() throws {
        guard ProcessInfo.processInfo.environment["CHANNELS_EXT"] == "1" else { throw XCTSkip("CHANNELS_EXT not set") }
        launch(mode: "guide")
        if openTV() {
            remote.press(.down)
            sleep(1)
            remote.press(.down)
            shot("r6-79-guide-external", delay: 4)
            // onto the first external row (its programme on air)
            let external = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "100 · ")).firstMatch
            if external.exists { focusByGeometry(external) } else { remote.press(.down); sleep(1) }
            remote.press(.select)
            shot("r6-80-external-programme", delay: 3)
            remote.press(.menu)
            sleep(1)
        }
    }

    /// A channel with many voices and subtitles (make it the profile's last channel first):
    /// the list, the banner and the mini-guide with its logo; the Audio list scrolls to its
    /// last entry and plays it; the Subtitles list with every language.
    func testManyVoices() {
        launch()
        XCTAssertTrue(openTV(), "no TV tab: \(focusedLabel)")
        shot("r5-60-list-logo", delay: 4)
        remote.press(.select)
        shot("r5-61-banner-logo", delay: 10)
        remote.press(.right)
        sleep(2)
        let audio = app.buttons["live.audio"]
        if audio.exists {
            moveFocus(.left, to: audio, limit: 4)
            remote.press(.select)
            shot("r5-62-audio-long", delay: 2)
            // to the last of the eight voices (one more Down would leave the list)
            for _ in 0..<7 { remote.press(.down); usleep(400_000) }
            shot("r5-63-audio-scrolled", delay: 1)
            remote.press(.select)
            sleep(3)
            // the list again: the tick on the picked voice
            if !(audio.exists && audio.hasFocus) { moveFocus(.left, to: audio, limit: 4) }
            remote.press(.select)
            shot("r5-64-audio-picked", delay: 2)
            // Select on the ticked row keeps it and closes the list
            remote.press(.select)
            sleep(2)
        }
        let subtitles = app.buttons["live.subtitles"]
        if moveFocus(.right, to: subtitles, limit: 4) {
            remote.press(.select)
            shot("r5-65-subtitles-long", delay: 2)
            for _ in 0..<5 { remote.press(.down); usleep(400_000) }
            remote.press(.select)
            sleep(4)
            if !(subtitles.exists && subtitles.hasFocus) { moveFocus(.right, to: subtitles, limit: 4) }
            remote.press(.select)
            shot("r5-66-subtitles-picked", delay: 2)
            remote.press(.select)
            shot("r5-66b-subtitles-on", delay: 4)
        }
        if !app.buttons["live.channels"].exists { remote.press(.right); sleep(2) }
        let channels = app.buttons["live.channels"]
        if moveFocus(.right, to: channels, limit: 5) {
            remote.press(.select)
            shot("r5-67-mini-guide-logo", delay: 3)
            remote.press(.menu)
            sleep(2)
        }
        remote.press(.menu)
        sleep(3)
    }

    /// The film player's Audio menu lists the voice-over file beside the video and plays it
    /// (`CHANNELS_FILM_ID`, «Тихий дом» of the test library by default).
    func testFilmVoiceOver() {
        launch()
        // Movies, newest first: the film is the first card.
        let film = ProcessInfo.processInfo.environment["CHANNELS_FILM"] ?? "Тихий дом"
        XCTAssertTrue(openSection(t("Movies", "Фильмы"), showing: app.staticTexts[t("Movies", "Фильмы")]), "no Movies tab")
        sleep(2)
        let card = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", film)).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 10), "no \(film)")
        XCTAssertTrue(focusByGeometry(card), "card not focused: \(focusedLabel)")
        remote.press(.select)
        sleep(3)
        let play = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@ OR label BEGINSWITH %@", t("Play", "Смотреть"), t("Resume", "Продолжить"))).firstMatch
        if play.waitForExistence(timeout: 5) { focusByGeometry(play) }
        shot("r3-38-film-page", delay: 1)
        remote.press(.select)
        shot("r3-39-film-playing", delay: 12)
        // The transport bar, then its Audio menu.
        remote.press(.select)
        shot("r3-39b-film-transport", delay: 2)
        // Up from the scrubber to the menu buttons; the Audio menu is the leftmost.
        remote.press(.up)
        sleep(1)
        for _ in 0..<4 {
            remote.press(.left)
            sleep(1)
        }
        shot("r3-40-film-transport", delay: 1)
        remote.press(.select)
        shot("r3-41-film-audio-menu", delay: 2)
        // The voice-over file is the last entry (after the file's own tracks).
        for _ in 0..<3 {
            remote.press(.down)
            sleep(1)
        }
        shot("r3-41b-film-voice-over-focused", delay: 1)
        remote.press(.select)
        shot("r3-42-film-voice-over-playing", delay: 12)
        remote.press(.select)
        sleep(2)
        remote.press(.up)
        sleep(1)
        for _ in 0..<4 {
            remote.press(.left)
            sleep(1)
        }
        remote.press(.select)
        shot("r3-43-film-audio-menu-after", delay: 2)
        remote.press(.menu)
        sleep(1)
        remote.press(.menu)
        sleep(2)
        remote.press(.menu)
        sleep(2)
    }

    /// The Top Shelf alone (after `testContinueZapAndMiniGuide` or any sign-in).
    func testTopShelf() {
        launch()
        sleep(5)
        topShelf("r3-30-top-shelf")
    }

    /// `antresol://channel/{id}` (the Top Shelf's link) opens the channel's live player. The
    /// system asks before opening a URL from outside; Select confirms. `CHANNELS_LINK_ID` picks
    /// the channel (3 by default).
    func testChannelLink() {
        launch()
        let id = ProcessInfo.processInfo.environment["CHANNELS_LINK_ID"] ?? "3"
        remote.press(.home)
        sleep(3)
        XCUIDevice.shared.system.open(URL(string: "antresol://channel/\(id)")!)
        sleep(2)
        remote.press(.select)
        shot("r3-31-link-opening", delay: 2)
        shot("r3-32-link-playing", delay: 10)
        // Menu leaves the player onto the TV tab.
        remote.press(.menu)
        shot("r3-33-link-back", delay: 3)
    }

    // MARK: - Helpers

    /// The Home screen with the app focused shows its Top Shelf («Сейчас в эфире»).
    /// `CHANNELS_HOME_MOVES`: how many apps to the right of the first one the app is.
    private func topShelf(_ name: String) {
        remote.press(.home)
        sleep(3)
        let moves = Int(ProcessInfo.processInfo.environment["CHANNELS_HOME_MOVES"] ?? "") ?? 2
        for _ in 0..<moves {
            remote.press(.right)
            sleep(1)
        }
        shot(name, delay: 15)
    }

    private var english: Bool {
        ProcessInfo.processInfo.environment["CHANNELS_LANGUAGE"] == "en"
    }

    /// The English or the Russian title, by the run's language.
    private func t(_ en: String, _ ru: String) -> String {
        english ? en : ru
    }

    /// Opens the TV tab and waits for the list.
    private func openTV() -> Bool {
        let marker = app.buttons[t("Channels", "Каналы")]
        let opened = openSection(t("TV", "ТВ"), showing: marker) || openSection(t("TV", "ТВ"), showing: marker)
        guard opened else { return false }
        // Focus may stay in the sidebar after choosing the tab: into the page.
        let focused = app.descendants(matching: .any).element(matching: NSPredicate(format: "hasFocus == true"))
        for _ in 0..<3 where focused.exists && focused.frame.minX < 1 && focused.frame.width < 600 {
            remote.press(.right)
            sleep(2)
        }
        return true
    }

    /// Moves focus towards `element` by where it is on screen.
    private func focusByGeometry(_ element: XCUIElement, limit: Int = 10) -> Bool {
        let focused = app.descendants(matching: .any).element(matching: NSPredicate(format: "hasFocus == true"))
        for _ in 0..<limit where !(element.exists && element.hasFocus) {
            guard focused.exists else {
                remote.press(.down)
                sleep(1)
                continue
            }
            let from = focused.frame, to = element.frame
            if to.maxY < from.minY {
                remote.press(.up)
            } else if to.minY > from.maxY {
                remote.press(.down)
            } else {
                remote.press(to.midX < from.midX ? .left : .right)
            }
            sleep(1)
        }
        return element.exists && element.hasFocus
    }

    /// Up to the filters, then sideways to `title`.
    private func focusFilter(_ title: String) -> Bool {
        let button = app.buttons[title]
        let focused = app.descendants(matching: .any).element(matching: NSPredicate(format: "hasFocus == true"))
        for _ in 0..<8 where !(button.exists && button.hasFocus) {
            if focused.exists, abs(focused.frame.midY - button.frame.midY) > 20 {
                remote.press(.up)
            } else {
                remote.press(focused.frame.midX < button.frame.midX ? .right : .left)
            }
            sleep(1)
        }
        return button.exists && button.hasFocus
    }

    /// Up to the view switch, then sideways to `title`.
    private func focusMode(_ title: String) -> Bool {
        focusFilter(title)
    }

    private func signIn(_ profile: String, password: String) {
        XCTAssertTrue(app.staticTexts[t("Who's watching?", "Кто смотрит?")].waitForExistence(timeout: 40), "no profile picker")
        let entry = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", profile)).firstMatch
        XCTAssertTrue(entry.waitForExistence(timeout: 10), "no profile \(profile)")
        XCTAssertTrue(moveFocus(.right, to: entry, limit: 8))
        remote.press(.select)
        if !password.isEmpty {
            let field = app.secureTextFields.firstMatch
            XCTAssertTrue(field.waitForExistence(timeout: 10), "no password field")
            sleep(1)
            if !field.hasFocus { moveFocus(.down, to: field, limit: 4) }
            remote.press(.select)  // opens the keyboard
            sleep(2)
            app.typeText(password)
            sleep(1)
            remote.press(.menu)  // closes the keyboard, the text stays
            sleep(2)
            moveFocus(.down, to: app.buttons[t("Sign In", "Войти")], limit: 4)
            remote.press(.select)
        }
        XCTAssertTrue(app.buttons[t("Details", "Подробнее")].waitForExistence(timeout: 40), "not signed in")
        sleep(3)
    }

    /// Left into the sidebar, then up or down to the entry titled `title` and select.
    @discardableResult
    private func openSection(_ title: String, showing marker: XCUIElement) -> Bool {
        let focused = app.descendants(matching: .any).element(matching: NSPredicate(format: "hasFocus == true"))
        func inSidebar() -> Bool { focused.exists && focused.frame.minX < 1 && focused.frame.width < 600 }
        for _ in 0..<6 where !inSidebar() {
            remote.press(.left)
            sleep(1)
        }
        guard inSidebar() else { return false }
        let candidates = app.buttons.matching(NSPredicate(format: "label == %@", title)).allElementsBoundByIndex
        guard let entry = candidates.first(where: { $0.frame.minX < 1 && $0.frame.width < 600 }) else { return false }
        for _ in 0..<10 {
            let delta = entry.frame.midY - focused.frame.midY
            if abs(delta) < 4 { break }
            remote.press(delta > 0 ? .down : .up)
            sleep(1)
        }
        remote.press(.select)
        return marker.waitForExistence(timeout: 20)
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
        return focused.exists ? focused.label : "none"
    }

    private func shot(_ name: String, delay: UInt32 = 3) {
        sleep(delay)
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = "channels-\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
        guard !dir.isEmpty else { return }
        try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("channels-\(name).png"))
    }
}
