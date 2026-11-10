import XCTest

/// The TV tab and the live player against a real server with channels (the mock server
/// has no live streams). Skipped unless `CHANNELS_SERVER` (the server's address),
/// `CHANNELS_PROFILE` (a profile's name) and `CHANNELS_PASSWORD` are set, as
/// `TEST_RUNNER_CHANNELS_…` for `xcodebuild test`; `CHANNELS_SHOTS_DIR` also gets the PNGs.
/// Runs in Russian, the channels' own language.
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
            "-app.language", "ru", "-AppleLanguages", "(en)", "-AppleLocale", "ru_RU",
        ]
        app.launch()
        signIn(profile, password: env["CHANNELS_PASSWORD"] ?? "")
    }

    func testChannelsAndLivePlayer() {
        XCTAssertTrue(openSection("ТВ", showing: app.buttons["Все"]), "no TV tab: \(focusedLabel)")
        // All sections (the pill remembers the last one).
        XCTAssertTrue(moveFocus(.up, to: app.buttons["Все"], limit: 4))
        remote.press(.select)
        shot("1-tv-all", delay: 4)
        remote.press(.down)
        shot("2-tv-all-focused", delay: 2)

        // The second section of the pill: its channels in a grid.
        XCTAssertTrue(moveFocus(.up, to: app.buttons["Все"], limit: 4))
        remote.press(.right)
        sleep(1)
        remote.press(.right)
        sleep(1)
        let section = focusedLabel
        remote.press(.select)
        shot("3-tv-section", delay: 3)

        // The section's first channel: the live player.
        remote.press(.down)
        sleep(1)
        let channel = focusedLabel
        remote.press(.select)
        shot("4-player-starting", delay: 1)
        shot("5-player-playing", delay: 10)
        shot("6-player-playing-later", delay: 5)

        // Select brings the panel back.
        remote.press(.select)
        shot("7-player-info", delay: 2)

        // Channel up: the next channel by number, with the panel; then back down.
        remote.press(.up)
        shot("8-player-channel-up", delay: 2)
        shot("9-player-channel-up-playing", delay: 10)
        remote.press(.down)
        shot("10-player-channel-down", delay: 10)

        remote.press(.menu)
        sleep(3)
        XCTAssertTrue(app.buttons["Все"].waitForExistence(timeout: 10), "Menu should leave the player (\(section), \(channel))")
        shot("11-back-to-section", delay: 1)
    }

    // MARK: - Helpers

    private func signIn(_ profile: String, password: String) {
        XCTAssertTrue(app.staticTexts["Кто смотрит?"].waitForExistence(timeout: 40), "no profile picker")
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
            moveFocus(.down, to: app.buttons["Войти"], limit: 4)
            remote.press(.select)
        }
        XCTAssertTrue(app.buttons["Подробнее"].waitForExistence(timeout: 40), "not signed in")
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
