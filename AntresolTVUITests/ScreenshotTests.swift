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

    func test06Music() {
        let app = signInAsKid()

        // Tab bar: Search, Home, Movies, TV Shows, Music. Focus starts on Home.
        for _ in 0..<3 {
            remote.press(.right)
            pause(1)
        }
        XCTAssertTrue(app.buttons["Shuffle All"].waitForExistence(timeout: 20))
        pause(3)
        snapshot(app, "25-music-listen-now")

        // Section pill, Shuffle All, then the first album of the first shelf.
        for _ in 0..<3 {
            remote.press(.down)
            pause(1)
        }
        remote.press(.select)
        let play = app.buttons["Play"]
        XCTAssertTrue(play.waitForExistence(timeout: 20))
        pause(3)
        XCTAssertTrue(play.hasFocus, "The album page should start on Play")
        snapshot(app, "26-album-detail")

        // Into the track list; the first song (it has lyrics) brings up Now Playing.
        remote.press(.down)
        pause(2)
        snapshot(app, "27-album-tracks")
        remote.press(.select)
        XCTAssertTrue(app.buttons["Lyrics"].waitForExistence(timeout: 20))
        pause(4)
        XCTAssertTrue(app.buttons["Pause"].hasFocus, "Now Playing should start on Play/Pause")
        snapshot(app, "28-now-playing")

        // Across the controls into the right panel, up to its pill, then Lyrics.
        for _ in 0..<4 {
            remote.press(.right)
            pause(1)
        }
        moveFocus(.up, to: app.buttons["Up Next"], limit: 3)
        XCTAssertTrue(moveFocus(.right, to: app.buttons["Lyrics"], limit: 2))
        remote.press(.select)
        pause(3)
        snapshot(app, "29-now-playing-lyrics")

        // Close Now Playing and the album, then the Albums section.
        remote.press(.menu)
        pause(2)
        remote.press(.menu)
        pause(2)
        moveFocus(.up, to: app.buttons["Listen Now"], limit: 6)
        XCTAssertTrue(moveFocus(.right, to: app.buttons["Albums"], limit: 2))
        remote.press(.select)
        pause(3)
        snapshot(app, "30-music-albums")
    }

    func test07Books() {
        let app = signInAsKid()

        // Tab bar: Search, Home, Movies, TV Shows, Music, Books.
        for _ in 0..<4 {
            remote.press(.right)
            pause(1)
        }
        pause(3)
        snapshot(app, "31-books-home")

        // Down to Currently Reading, then left to the comic volume.
        remote.press(.down)
        pause(1)
        remote.press(.down)
        pause(1)
        XCTAssertTrue(moveFocus(.left, to: card(app, "Hero Tales"), limit: 4))
        remote.press(.select)
        let read = app.buttons.matching(NSPredicate(format: "label IN %@", ["Read", "Continue Reading"])).firstMatch
        XCTAssertTrue(read.waitForExistence(timeout: 20))
        pause(3)
        snapshot(app, "32-comic-volume")
        remote.press(.select)
        pause(5)
        snapshot(app, "33-comic-reader")
        // A right-to-left volume: left turns the page forward.
        remote.press(.left)
        pause(3)
        snapshot(app, "34-comic-spread")
        remote.press(.menu)
        pause(3)
        remote.press(.menu)
        pause(2)

        // The audiobook at the end of the shelf.
        XCTAssertTrue(moveFocus(.right, to: card(app, "Chapter Book"), limit: 4))
        remote.press(.select)
        XCTAssertTrue(app.buttons["Want to Read"].waitForExistence(timeout: 20))
        pause(3)
        XCTAssertTrue(app.buttons["Play"].hasFocus, "The audiobook page should start on Play")
        snapshot(app, "35-audiobook-detail")
        remote.press(.select)
        pause(5)
        snapshot(app, "36-audiobook-now-playing")
    }

    func test08Settings() {
        let app = signInAsKid()

        // The profile tab is the last one.
        for _ in 0..<7 {
            remote.press(.right)
            pause(1)
        }
        XCTAssertTrue(app.buttons["Switch Profile"].waitForExistence(timeout: 20))
        pause(2)
        snapshot(app, "37-settings")

        // Into the settings list, then the App Language page.
        remote.press(.down)
        pause(1)
        moveFocus(.right, to: setting(app, "Video Quality"), limit: 3)
        XCTAssertTrue(moveFocus(.down, to: setting(app, "App Language"), limit: 6))
        remote.press(.select)
        pause(3)
        snapshot(app, "38-settings-language")
        remote.press(.menu)
        pause(2)

        XCTAssertTrue(moveFocus(.down, to: setting(app, "Acknowledgements"), limit: 8))
        pause(1)
        snapshot(app, "39-settings-server-about")
        remote.press(.select)
        pause(2)
        snapshot(app, "40-acknowledgements")
    }

    func test09DeepLinkAndRussian() {
        // antresol://item/19 opens the movie's page on Home once signed in.
        let app = launch(
            arguments: ["-AntresolResetSession", "YES", "-AntresolServerURL", server, "-AntresolOpenURL", "antresol://item/19"],
            language: "ru"
        )
        XCTAssertTrue(app.staticTexts["Кто смотрит?"].waitForExistence(timeout: 30))
        pause(2)
        snapshot(app, "41-profiles-ru")
        remote.press(.right)
        remote.press(.select)
        pause(6)
        snapshot(app, "42-deep-link-detail-ru")
        remote.press(.menu)
        pause(3)
        snapshot(app, "43-home-ru")
        for _ in 0..<8 {
            remote.press(.up)
        }
        for _ in 0..<7 {
            remote.press(.right)
            pause(1)
        }
        pause(2)
        snapshot(app, "44-settings-ru")

        // The Home screen with the app focused shows its Top Shelf.
        XCUIRemote.shared.press(.home)
        pause(10)
        snapshot(XCUIScreen.main, "45-top-shelf")
    }

    /// The poster card whose title starts with `title`.
    private func card(_ app: XCUIApplication, _ title: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", title)).firstMatch
    }

    /// Presses `direction` until `element` has focus, at most `limit` times.
    @discardableResult
    private func moveFocus(_ direction: XCUIRemote.Button, to element: XCUIElement, limit: Int) -> Bool {
        for _ in 0..<limit {
            if element.exists && element.hasFocus { return true }
            remote.press(direction)
            pause(1)
        }
        return element.exists && element.hasFocus
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

    /// A settings row by its title (its label also carries the value).
    private func setting(_ app: XCUIApplication, _ title: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", title)).firstMatch
    }

    private func launch(arguments: [String], language: String = "en") -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += arguments + ["-AppleLanguages", "(\(language))"]
        app.launch()
        return app
    }

    private func pause(_ seconds: UInt32) {
        sleep(seconds)
    }

    private func snapshot(_ source: XCUIScreenshotProviding, _ name: String) {
        let attachment = XCTAttachment(screenshot: source.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
