import XCTest

/// Drives the app against `scripts/mock-server.py` and attaches a screenshot of every
/// main screen. CI exports them as the `ui-screenshots` artifact for visual review.
final class ScreenshotTests: XCTestCase {
    private let server = ProcessInfo.processInfo.environment["ANTRESOL_MOCK_SERVER"] ?? "127.0.0.1:8421"
    private let remote = XCUIRemote.shared

    override func setUp() {
        continueAfterFailure = true
    }

    func test01ServerEntry() {
        let app = launch(arguments: ["-AntresolResetSession", "YES"])
        XCTAssertTrue(app.staticTexts["Connect to your server"].waitForExistence(timeout: 20))
        snapshot(app, "01-server-entry")
    }

    func test02OnboardingAndHome() {
        let app = launch(arguments: ["-AntresolResetSession", "YES", "-AntresolServerURL", server])
        XCTAssertTrue(app.staticTexts["Who's watching?"].waitForExistence(timeout: 30))
        pause(2)
        snapshot(app, "02-profiles")

        // The first profile (Admin) is protected.
        remote.press(.select)
        XCTAssertTrue(app.secureTextFields.firstMatch.waitForExistence(timeout: 10))
        pause(1)
        snapshot(app, "03-password")
        remote.press(.menu)
        pause(1)

        // The second profile signs in without a password.
        remote.press(.right)
        remote.press(.select)
        XCTAssertTrue(app.buttons["Details"].waitForExistence(timeout: 30))
        pause(4)
        snapshot(app, "04-home-hero")

        // Focus starts on the tab bar: down to the hero's Resume pill, right to Details.
        remote.press(.down)
        pause(1)
        remote.press(.right)
        pause(1)
        remote.press(.select)
        pause(4)
        snapshot(app, "05-movie-detail")
        remote.press(.menu)
        pause(2)

        // Back on Details; move into the shelves.
        for _ in 0..<2 {
            remote.press(.down)
            pause(1)
        }
        pause(2)
        snapshot(app, "06-home-shelves")

        remote.press(.select)
        pause(4)
        snapshot(app, "07-album-detail")
        remote.press(.menu)
        pause(2)

        for _ in 0..<8 {
            remote.press(.up)
        }
        pause(1)
        for _ in 0..<6 {
            remote.press(.right)
        }
        pause(3)
        snapshot(app, "08-account")
    }

    func test03BrowseDetailsAndSearch() {
        let app = signInAsKid()

        // Tab bar order: Search, Home, Movies, TV Shows... Focus starts on Home.
        remote.press(.right)
        pause(4)
        snapshot(app, "09-movies")

        // Into the grid (the first press may land on the sort pill) and open a poster.
        remote.press(.down)
        pause(1)
        remote.press(.down)
        pause(1)
        remote.press(.select)
        pause(4)
        snapshot(app, "10-movie-detail")
        for _ in 0..<3 {
            remote.press(.down)
            pause(1)
        }
        pause(1)
        snapshot(app, "11-movie-about")
        remote.press(.menu)
        pause(2)
        remote.press(.menu)
        pause(2)

        // TV Shows tab, then the show's page.
        remote.press(.right)
        pause(4)
        snapshot(app, "12-shows")
        remote.press(.down)
        pause(1)
        remote.press(.down)
        pause(1)
        remote.press(.select)
        pause(4)
        snapshot(app, "13-series-detail")
        remote.press(.down)
        pause(1)
        remote.press(.down)
        pause(2)
        snapshot(app, "14-series-episodes")
        remote.press(.select)
        pause(4)
        snapshot(app, "15-episode-detail")
        remote.press(.menu)
        pause(1)
        remote.press(.menu)
        pause(1)
        remote.press(.menu)
        pause(2)

        // Search tab: Browse tiles, then results.
        for _ in 0..<3 {
            remote.press(.left)
            pause(1)
        }
        pause(3)
        snapshot(app, "16-search")
        // Down from the tab bar into the keyboard, which gives the field keyboard focus.
        remote.press(.down)
        pause(2)
        app.searchFields.firstMatch.typeText("test")
        pause(4)
        remote.press(.down)
        pause(2)
        snapshot(app, "17-search-results")
    }

    func test04Player() {
        // English subtitles preferred, so the side-loaded overlay shows from the start.
        let app = signInAsKid(extraArguments: ["-player.subtitleLanguage", "en"])

        // Tab bar → hero buttons → first Continue Watching card (a movie with progress).
        remote.press(.down)
        pause(1)
        remote.press(.down)
        pause(2)
        remote.press(.select)
        XCTAssertTrue(app.buttons["Start Over"].waitForExistence(timeout: 20))
        pause(3)
        snapshot(app, "18-resume-prompt")

        remote.press(.select)
        pause(8)
        snapshot(app, "19-player-subtitles")

        // Pause: the transport bar with the Audio / Subtitles / Quality menus.
        remote.press(.select)
        pause(3)
        snapshot(app, "20-player-transport")
        // Up from the scrubber reaches the menu buttons next to the title.
        remote.press(.up)
        pause(2)
        snapshot(app, "21-player-menu-button")
        remote.press(.select)
        pause(2)
        snapshot(app, "22-player-menu")

        exitPlayer(app)
    }

    func test05UpNext() {
        let app = signInAsKid()

        // The episode in Continue Watching (third card); its resume point is close to
        // the end, so the Up Next panel comes up right away.
        remote.press(.down)
        pause(1)
        remote.press(.down)
        pause(2)
        remote.press(.right)
        pause(1)
        remote.press(.right)
        pause(1)
        remote.press(.select)
        XCTAssertTrue(app.buttons["Start Over"].waitForExistence(timeout: 20))
        pause(1)
        snapshot(app, "23-episode-resume")
        remote.press(.select)
        pause(6)
        snapshot(app, "24-up-next")
        exitPlayer(app)
    }

    /// Menu until the player is gone (it may first close a panel or the transport bar).
    private func exitPlayer(_ app: XCUIApplication) {
        for _ in 0..<4 {
            remote.press(.menu)
            pause(2)
            if app.buttons["Details"].exists { break }
        }
        XCTAssertTrue(app.buttons["Details"].waitForExistence(timeout: 20))
    }

    /// Fresh session, then the passwordless second profile.
    private func signInAsKid(extraArguments: [String] = []) -> XCUIApplication {
        let app = launch(arguments: ["-AntresolResetSession", "YES", "-AntresolServerURL", server] + extraArguments)
        XCTAssertTrue(app.staticTexts["Who's watching?"].waitForExistence(timeout: 30))
        pause(2)
        remote.press(.right)
        remote.press(.select)
        XCTAssertTrue(app.buttons["Details"].waitForExistence(timeout: 30))
        pause(3)
        return app
    }

    private func launch(arguments: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += arguments + ["-AppleLanguages", "(en)"]
        app.launch()
        return app
    }

    private func pause(_ seconds: UInt32) {
        sleep(seconds)
    }

    private func snapshot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
