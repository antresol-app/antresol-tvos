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
