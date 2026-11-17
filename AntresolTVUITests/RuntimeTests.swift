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
        XCTAssertTrue(app.buttons["live.track.English"].waitForNonExistence(timeout: 5), "the audio list did not close")
        sleep(1)
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
    /// answers after 4 s; a seek after that reloads the stream at the new position
    /// (`t=` in the mock's log), as a transcoded song needs.
    func testTranscodedSong() {
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

        let started = Date()
        remote.press(.select)
        let position = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Playback Position")).firstMatch
        XCTAssertTrue(position.waitForExistence(timeout: 20), "no Now Playing")
        // The clock leaves 0:00 before the mock answers the app's own request.
        var moved: TimeInterval?
        while Date().timeIntervalSince(started) < 15 {
            if let value = position.value as? String, value != "0:00" {
                moved = Date().timeIntervalSince(started)
                break
            }
            usleep(200_000)
        }
        XCTAssertNotNil(moved, "the song did not start")
        snapshot("rt-30-transcoded-song-playing")
        // By now the app knows the song is transcoded: a seek asks for the stream again.
        sleep(5)
        XCTAssertTrue(moveFocus(.up, to: position, limit: 3), "focus: \(focusedLabel)")
        remote.press(.right)
        sleep(4)
        XCTAssertTrue(app.buttons["Pause"].exists, "not playing after the seek")
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

    // MARK: - Helpers

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
        let focused = app.descendants(matching: .any).element(matching: NSPredicate(format: "hasFocus == true"))
        func inSidebar() -> Bool { focused.exists && focused.frame.minX < 1 && focused.frame.width < 600 && focused.frame.height < 150 }
        for _ in 0..<2 {
            for _ in 0..<6 where !inSidebar() {
                remote.press(.left)
                sleep(1)
            }
            let entries = app.buttons.matching(NSPredicate(format: "label == %@", "TV")).allElementsBoundByIndex
            guard inSidebar(), let entry = entries.first(where: { $0.frame.minX < 1 && $0.frame.width < 600 }) else { continue }
            for _ in 0..<10 where inSidebar() {
                let delta = entry.frame.midY - focused.frame.midY
                if abs(delta) < 4 { break }
                remote.press(delta > 0 ? .down : .up)
                sleep(1)
            }
            guard inSidebar(), abs(entry.frame.midY - focused.frame.midY) < 4 else { continue }
            remote.press(.select)
            if app.buttons["Guide"].waitForExistence(timeout: 20) { return true }
        }
        return false
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
