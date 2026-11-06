import XCTest

/// App Store screenshots from the public demo server (open-licensed content only), and a
/// smoke run of the app against a real server. Skipped unless `DEMO_PASSWORD` is set
/// (`TEST_RUNNER_DEMO_PASSWORD`) and `DEMO_SERVER` (the server's address), `STORE_SHOTS_DIR`
/// also gets the PNGs (`tv-<n>-<name>.png`, 3840x2160 on an Apple TV 4K simulator).
final class StoreScreenshotTests: XCTestCase {
    private let remote = XCUIRemote.shared
    private var dir = ""
    private let app = XCUIApplication()

    override func setUpWithError() throws {
        let env = ProcessInfo.processInfo.environment
        guard let password = env["DEMO_PASSWORD"], !password.isEmpty else { throw XCTSkip("DEMO_PASSWORD not set") }
        continueAfterFailure = false
        dir = env["STORE_SHOTS_DIR"] ?? ""
        guard let server = env["DEMO_SERVER"], !server.isEmpty else { throw XCTSkip("DEMO_SERVER not set") }
        // Music opens on Listen Now whatever pane the simulator remembers
        app.launchArguments += ["-AntresolResetSession", "YES", "-music.section", "listenNow", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        connect(server)
        signIn(password)
    }

    /// The address screen as a reviewer meets it: type the server, Connect.
    private func connect(_ server: String) {
        let field = app.textFields.firstMatch
        guard field.waitForExistence(timeout: 15) else { return }
        remote.press(.select)
        sleep(1)
        field.typeText(server + "\n")
        sleep(2)
        let connect = app.buttons["Connect"]
        if connect.exists && !app.staticTexts["Who's watching?"].exists {
            focus(connect, limit: 4, direction: .down)
            remote.press(.select)
        }
    }

    private func signIn(_ password: String) {
        if !app.staticTexts["Who's watching?"].waitForExistence(timeout: 40) { shot("0-start", delay: 0); dump("start") }
        XCTAssertTrue(app.staticTexts["Who's watching?"].exists, "no profile picker")
        let review = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'App Review'")).firstMatch
        XCTAssertTrue(review.waitForExistence(timeout: 10), "no App Review profile")
        XCTAssertTrue(focus(review, limit: 8), "cannot focus App Review")
        remote.press(.select)
        let field = app.secureTextFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10), "no password field")
        sleep(1)
        if !field.hasFocus { focus(field, limit: 4, direction: .down) }
        remote.press(.select)  // opens the keyboard
        sleep(2)
        app.typeText(password)
        sleep(1)
        remote.press(.menu)  // closes the keyboard, the text stays
        sleep(2)
        let signIn = app.buttons["Sign In"]
        focus(signIn, limit: 4, direction: .down)
        remote.press(.select)
        if !app.buttons["Details"].waitForExistence(timeout: 40) { shot("0-after-password", delay: 0); dump("after-password") }
        XCTAssertTrue(app.buttons["Details"].exists, "not signed in")
        sleep(4)
    }

    /// Moves focus right, then down, until `element` has it.
    @discardableResult
    private func focus(_ element: XCUIElement, limit: Int, direction: XCUIRemote.Button = .right) -> Bool {
        for _ in 0...limit {
            if element.hasFocus { return true }
            remote.press(direction)
            usleep(400_000)
        }
        return element.hasFocus
    }

    private func shot(_ name: String, delay: UInt32 = 3) {
        sleep(delay)
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = "tv-\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
        guard !dir.isEmpty else { return }
        try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("tv-\(name).png"))
    }

    private func dump(_ name: String) {
        guard !dir.isEmpty else { return }
        try? app.debugDescription.write(toFile: dir + "/tree-\(name).txt", atomically: true, encoding: .utf8)
    }

    /// The element with focus.
    private var focused: XCUIElement {
        app.descendants(matching: .any).element(matching: NSPredicate(format: "hasFocus == true"))
    }

    /// Moves focus towards `element` with the remote, one press at a time.
    @discardableResult
    private func moveFocus(to element: XCUIElement, limit: Int = 25) -> Bool {
        guard element.waitForExistence(timeout: 15) else { return false }
        for _ in 0..<limit {
            if element.hasFocus { return true }
            let f = focused
            guard f.exists else { remote.press(.right); usleep(500_000); continue }
            let a = f.frame, b = element.frame
            let dx = b.midX - a.midX, dy = b.midY - a.midY
            if abs(dy) > max(abs(dx), 20) { remote.press(dy > 0 ? .down : .up) } else { remote.press(dx > 0 ? .right : .left) }
            usleep(600_000)
        }
        return element.hasFocus
    }

    private func button(_ prefix: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@ OR identifier == %@", prefix, prefix)).firstMatch
    }

    /// A sidebar section by its title: Left until the sidebar has focus, then up or down to
    /// its full-width row at the screen's left edge (as ScreenshotTests.openSection).
    private func section(_ title: String) {
        func inSidebar() -> Bool { let f = focused; return f.exists && f.frame.minX < 1 && f.frame.width < 600 }
        for _ in 0..<6 where !inSidebar() {
            remote.press(.left); sleep(1)
        }
        let entry = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", title)).allElementsBoundByIndex
            .first { $0.frame.minX < 1 && $0.frame.width < 600 && $0.frame.width > 0 }
        if entry == nil { shot("0-no-\(title)", delay: 0); dump("no-section") }
        XCTAssertNotNil(entry, "no section \(title)")
        for _ in 0..<10 {
            guard let entry, focused.exists else { break }
            let delta = entry.frame.midY - focused.frame.midY
            if abs(delta) < 4 { break }
            remote.press(delta > 0 ? .down : .up); sleep(1)
        }
        remote.press(.select)
        sleep(4)
    }

    private func open(_ prefix: String) {
        let ok = moveFocus(to: button(prefix))
        if !ok { shot("0-unreached", delay: 0); dump("unreached") }
        XCTAssertTrue(ok, "cannot reach \(prefix)")
        remote.press(.select)
        sleep(4)
    }

    func testStoreScreens() throws {
        // Home: into the hero (the sidebar folds away)
        remote.press(.right)
        shot("1-home", delay: 4)

        // a series from the hero's info button
        open("info.circle")
        shot("2-series")
        remote.press(.menu)
        sleep(2)

        section("Movies")
        remote.press(.right)
        shot("3-movies", delay: 4)
        open("Sintel")
        shot("4-movie")

        // the player, paused with its info showing
        open("Resume")
        sleep(10)
        remote.press(.select)
        shot("5-player", delay: 2)
        // Menu until the film's page is back (the info panel, then the player close)
        for _ in 0..<4 where !app.buttons["Resume"].hasFocus {
            remote.press(.menu)
            sleep(3)
        }
        dump("after-player")
        remote.press(.menu)
        sleep(2)

        section("Music")
        open("The Shade from Our Trees")
        shot("6-album")
        open("Play")
        sleep(4)
        shot("7-now-playing")
        dump("now-playing")
    }
}
