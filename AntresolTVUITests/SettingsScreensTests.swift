import XCTest

/// The settings screens, in English and Russian (`TEST_RUNNER_ANTRESOL_TEST_LANGUAGE`), against
/// `scripts/mock-server.py` (`TEST_RUNNER_ANTRESOL_MOCK_SERVER`; its second port has the passwordless adult
/// profile): the profile page with its choice pages, the separate-history page, the setup screens
/// before a server is chosen, «Кто смотрит?» and the password. Each screen is checked for texts and
/// controls that overlap; with `SHOTS_DIR` (`TEST_RUNNER_SHOTS_DIR`) each is also
/// saved as `<SHOTS_DIR>/<name>.png` (1920x1080 on the Apple TV 4K at 1080p simulator).
///
/// The setup screens run with discovery off (`-AntresolNoDiscovery`) and no server given, and Select is
/// pressed only on a control the test saw focused: a test never connects to a server it was not given.
final class SettingsScreensTests: XCTestCase {
    private let server = ProcessInfo.processInfo.environment["ANTRESOL_MOCK_SERVER"] ?? "127.0.0.1:8421"
    private let language = ProcessInfo.processInfo.environment["ANTRESOL_TEST_LANGUAGE"] ?? "en"
    private let shotsDir = ProcessInfo.processInfo.environment["SHOTS_DIR"] ?? ""
    private let remote = XCUIRemote.shared
    private let app = XCUIApplication()

    override func setUp() {
        continueAfterFailure = true
    }

    // MARK: screens

    func testSetupScreens() {
        app.launchArguments += ["-AntresolResetSession", "YES", "-AntresolNoDiscovery", "YES", "-AppleLanguages", "(\(language))"]
        app.launch()
        let enter = app.buttons[tr("Enter Address with the Remote")]
        XCTAssertTrue(enter.waitForExistence(timeout: 30), "no setup screen")
        XCTAssertTrue(waitForFocus(enter), "focus is not on «Enter Address with the Remote»: \(focusedLabel)")
        look("setup-phone", settle: 3)
        remote.press(.select)
        XCTAssertTrue(app.textFields.firstMatch.waitForExistence(timeout: 10), "no address field")
        look("setup-address", settle: 2)
    }

    func testProfilesAndPassword() {
        launch(server: server)
        XCTAssertTrue(app.staticTexts[tr("Who's watching?")].waitForExistence(timeout: 30))
        look("profiles", settle: 3)
        // the first profile has a password: its entry screen
        remote.press(.select)
        XCTAssertTrue(app.secureTextFields.firstMatch.waitForExistence(timeout: 10), "no password field")
        look("password", settle: 2)
    }

    func testSettingsOfAKid() {
        launch(server: server)
        signIn(profilesToTheRight: 1)
        openSettings(name: "Kiddo")
        look("settings-kid", settle: 2)
        scrollSettings(to: tr("Acknowledgements"))
        look("settings-kid-end", settle: 1)
        choicePages()
    }

    func testSettingsOfAnAdult() {
        launch(server: pairingServer)
        XCTAssertTrue(app.staticTexts[tr("Sign in with your phone")].waitForExistence(timeout: 30), "no QR sign-in screen")
        look("signin-phone", settle: 2)
        XCTAssertTrue(waitForFocus(app.buttons[tr("Sign In with the Remote")]), "focus: \(focusedLabel)")
        remote.press(.select)
        XCTAssertTrue(app.staticTexts[tr("Who's watching?")].waitForExistence(timeout: 30))
        signIn(profilesToTheRight: 2, alreadyAtPicker: true)
        openSettings(name: "Family")
        look("settings-adult", settle: 2)
        scrollSettings(to: tr("Separate History"))
        look("settings-adult-history-row", settle: 1)
        remote.press(.select)
        XCTAssertTrue(app.staticTexts[tr("Separate History")].waitForExistence(timeout: 10), "no history page")
        look("history", settle: 2)
        let new = setting(tr("New History…"))
        if moveFocus(.down, to: new, limit: 6) {
            remote.press(.select)
            sleep(2)
            look("history-new", settle: 1)
            remote.press(.menu)
            sleep(1)
        }
        remote.press(.menu)
        sleep(1)
        // Sign Out asks first
        openSettings(name: "Family")
        remote.press(.left)
        sleep(1)
        let signOut = app.buttons[tr("Sign Out")]
        for _ in 0..<3 where !(signOut.exists && signOut.hasFocus) {
            remote.press(.down)
            sleep(1)
        }
        if signOut.exists && signOut.hasFocus {
            remote.press(.select)
            sleep(2)
            look("sign-out-confirm", settle: 1)
            remote.press(.menu)
        } else {
            XCTFail("focus did not reach Sign Out: \(focusedLabel)")
        }
    }

    /// The pages the rows open: video quality, audio language, subtitles, interface language, acknowledgements.
    private func choicePages() {
        for (index, title) in ["Video Quality", "Audio Language", "Subtitles", "Interface Language"].enumerated() {
            scrollSettings(to: tr(title))
            remote.press(.select)
            sleep(2)
            look("choice-\(index + 1)-\(title.lowercased().replacingOccurrences(of: " ", with: "-"))", settle: 1)
            remote.press(.menu)
            sleep(2)
        }
        scrollSettings(to: tr("Acknowledgements"))
        remote.press(.select)
        sleep(2)
        look("acknowledgements", settle: 1)
        remote.press(.menu)
        sleep(1)
    }

    // MARK: navigation

    private func launch(server: String) {
        app.launchArguments += ["-AntresolResetSession", "YES", "-AntresolServerURL", server, "-AntresolNoDiscovery", "YES",
                                "-AppleLanguages", "(\(language))", "-tv.mode", "channels", "-tv.filter", "all"]
        app.launch()
    }

    /// Fresh session: «Кто смотрит?», then the profile `profilesToTheRight` places after the first.
    private func signIn(profilesToTheRight: Int, alreadyAtPicker: Bool = false) {
        if !alreadyAtPicker {
            XCTAssertTrue(app.staticTexts[tr("Who's watching?")].waitForExistence(timeout: 30))
        }
        sleep(2)
        for _ in 0..<profilesToTheRight { remote.press(.right) }
        remote.press(.select)
        XCTAssertTrue(app.buttons[tr("Details")].waitForExistence(timeout: 30), "no Home")
        sleep(3)
    }

    /// The profile entry of the sidebar, then the settings page.
    private func openSettings(name: String) {
        XCTAssertTrue(openSection(name, showing: app.buttons[tr("Switch Profile")]), "no Settings: \(focusedLabel)")
        sleep(2)
        remote.press(.down)
        sleep(1)
        moveFocus(.right, to: setting(tr("Video Quality")), limit: 3)
    }

    /// Down the list of rows until `title` has focus (a scroll brings the rows in).
    private func scrollSettings(to title: String) {
        let row = setting(title)
        if !(row.exists && row.hasFocus) {
            if !moveFocus(.down, to: row, limit: 10) { _ = moveFocus(.up, to: row, limit: 10) }
        }
        sleep(1)
    }

    private func openSection(_ title: String, showing marker: XCUIElement) -> Bool {
        let focused = app.descendants(matching: .any).element(matching: NSPredicate(format: "hasFocus == true"))
        func inSidebar() -> Bool { focused.exists && focused.frame.minX < 1 && focused.frame.width < 600 && focused.frame.height < 150 }
        for _ in 0..<2 {
            for _ in 0..<6 where !inSidebar() {
                remote.press(.left)
                sleep(1)
            }
            let entries = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", title)).allElementsBoundByIndex
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

    /// The app's own string for `key` in the language the run is in (the key itself in English).
    private func tr(_ key: String) -> String {
        guard language != "en" else { return key }
        let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("AntresolTV/Resources/\(language).lproj/Localizable.strings").path
        return (NSDictionary(contentsOfFile: path) as? [String: String])?[key] ?? key
    }

    /// The mock's port with QR sign-in: the one after the main port.
    private var pairingServer: String {
        let parts = server.split(separator: ":")
        guard parts.count == 2, let port = Int(parts[1]) else { return server }
        return "\(parts[0]):\(port + 1)"
    }

    // MARK: looking

    private func look(_ name: String, settle: UInt32) {
        sleep(settle)
        if !shotsDir.isEmpty {
            try? FileManager.default.createDirectory(atPath: shotsDir, withIntermediateDirectories: true)
            let png = XCUIScreen.main.screenshot().pngRepresentation
            try? png.write(to: URL(fileURLWithPath: shotsDir).appendingPathComponent("\(name).png"))
        }
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .deleteOnSuccess
        add(attachment)
        for problem in layoutProblems() { XCTFail("\(language) \(name): \(problem)") }
    }

    /// Texts and controls of the page that overlap (neither holds the other).
    /// The sidebar (rows that start at the screen's edge), the profile chip in the top corner and what is off the screen
    /// (the tabs' other content) are not the page.
    private func layoutProblems() -> [String] {
        guard let root = try? app.snapshot() else { return ["no accessibility tree"] }
        let screen = root.frame
        var leaves: [(label: String, frame: CGRect)] = []
        func walk(_ s: XCUIElementSnapshot) {
            let kinds: [XCUIElement.ElementType] = [.staticText, .button, .textField, .secureTextField, .switch]
            if kinds.contains(s.elementType), !s.frame.isEmpty, s.frame.width > 1, s.frame.height > 1,
               s.frame.minX >= 1, s.frame.minY >= 130, s.frame.maxY <= screen.maxY + 1 {
                let name = s.label.isEmpty ? s.identifier : s.label
                if !name.isEmpty { leaves.append((String(name.prefix(40)), s.frame)) }
            }
            for child in s.children { walk(child) }
        }
        walk(root)
        var out: [String] = []
        for (i, a) in leaves.enumerated() {
            for b in leaves[(i + 1)...] {
                let inter = a.frame.intersection(b.frame)
                guard !inter.isNull, inter.width > 2, inter.height > 2 else { continue }
                let slack: CGFloat = 2
                if a.frame.insetBy(dx: -slack, dy: -slack).contains(b.frame) || b.frame.insetBy(dx: -slack, dy: -slack).contains(a.frame) { continue }
                out.append("«\(a.label)» and «\(b.label)» overlap by \(Int(inter.width))x\(Int(inter.height))")
            }
        }
        return out
    }
}
