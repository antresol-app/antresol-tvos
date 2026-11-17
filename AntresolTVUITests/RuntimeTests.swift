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

    // MARK: - Helpers

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
