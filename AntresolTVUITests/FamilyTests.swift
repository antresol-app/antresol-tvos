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
