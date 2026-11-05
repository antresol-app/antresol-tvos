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
        // The mock's second profile is a kid profile, which cannot change the server.
        XCTAssertFalse(setting(app, "Change Server").exists)
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
        // The linked page takes the focus from the tab bar, so Menu goes back to Home.
        XCTAssertTrue(app.buttons["Продолжить"].hasFocus, "The linked page should start on Resume")
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

        // The Home screen with the app focused shows its Top Shelf. The simulator's Home
        // screen starts on its first app (Settings); Antresol is the last in the top row.
        remote.press(.home)
        pause(3)
        for _ in 0..<3 {
            remote.press(.right)
            pause(1)
        }
        pause(12)
        snapshot(XCUIScreen.main, "45-top-shelf")
    }

    func test10Playlists() {
        let app = signInAsKid()

        // Music tab, then the Playlists section of the pill.
        for _ in 0..<3 {
            remote.press(.right)
            pause(1)
        }
        // The section pill remembers the last section (another test may have left Albums).
        XCTAssertTrue(app.buttons["Listen Now"].waitForExistence(timeout: 20))
        remote.press(.down)
        pause(1)
        XCTAssertTrue(moveFocus(.right, to: app.buttons["Playlists"], limit: 6))
        remote.press(.select)
        let newPlaylist = app.buttons["New Playlist"]
        XCTAssertTrue(newPlaylist.waitForExistence(timeout: 20))
        pause(2)
        snapshot(app, "46-playlists")

        // New Playlist: type a name and submit it from the keyboard.
        XCTAssertTrue(moveFocus(.down, to: newPlaylist, limit: 2))
        remote.press(.select)
        let field = app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        pause(1)
        snapshot(app, "47-new-playlist")
        remote.press(.select)
        pause(2)
        field.typeText("Road Trip\n")
        pause(3)
        if app.buttons["Create"].exists {
            // The keyboard closed without submitting: use the Create button.
            moveFocus(.down, to: app.buttons["Create"], limit: 3)
            remote.press(.select)
        }
        XCTAssertTrue(card(app, "Road Trip").waitForExistence(timeout: 15), "the new playlist is in the grid")
        pause(2)
        snapshot(app, "48-playlist-created")

        // The sample playlist: its songs can be moved, removed and added elsewhere.
        XCTAssertTrue(moveFocus(.down, to: card(app, "Renamed Mix"), limit: 3))
        remote.press(.select)
        XCTAssertTrue(app.buttons["Rename"].waitForExistence(timeout: 20))
        pause(3)
        snapshot(app, "49-playlist-detail")
        remote.press(.down)
        pause(1)
        remote.press(.select, forDuration: 1.5)
        let moveDown = menuItem(app, "Move Down")
        XCTAssertTrue(moveDown.waitForExistence(timeout: 10), "a playlist song offers Move Down: \(hierarchy(app, mentioning: "Move Down"))")
        XCTAssertTrue(menuItem(app, "Remove from Playlist").exists)
        pause(1)
        snapshot(app, "50-playlist-song-menu")
        if moveFocus(.down, to: moveDown, limit: 8) {
            remote.press(.select)
        }
        pause(3)
        snapshot(app, "51-playlist-reordered")

        // Add the focused song to the new playlist.
        remote.press(.select, forDuration: 1.5)
        let addToPlaylist = menuItem(app, "Add to Playlist…")
        XCTAssertTrue(addToPlaylist.waitForExistence(timeout: 10))
        if moveFocus(.down, to: addToPlaylist, limit: 6) {
            remote.press(.select)
        }
        XCTAssertTrue(app.staticTexts["Add to Playlist"].waitForExistence(timeout: 10))
        pause(2)
        snapshot(app, "52-add-to-playlist")
        XCTAssertTrue(moveFocus(.down, to: setting(app, "Road Trip"), limit: 4))
        remote.press(.select)
        XCTAssertTrue(app.staticTexts["Added to “Road Trip”"].waitForExistence(timeout: 10))
        snapshot(app, "53-added-to-playlist")

        // Back in the grid, delete the new playlist from its long-press menu.
        remote.press(.menu)
        pause(3)
        XCTAssertTrue(moveFocus(.right, to: card(app, "Road Trip"), limit: 3))
        remote.press(.select, forDuration: 1.5)
        let delete = menuItem(app, "Delete Playlist")
        XCTAssertTrue(delete.waitForExistence(timeout: 10))
        if moveFocus(.down, to: delete, limit: 3) {
            remote.press(.select)
        }
        pause(2)
        // The confirmation: Cancel and the destructive button side by side.
        let confirm = menuItem(app, "Delete Playlist")
        XCTAssertTrue(confirm.waitForExistence(timeout: 10), hierarchy(app, mentioning: "Delete Playlist"))
        snapshot(app, "54-delete-playlist")
        if moveFocus(.right, to: confirm, limit: 2) {
            remote.press(.select)
        }
        pause(3)
        XCTAssertFalse(card(app, "Road Trip").exists, "the deleted playlist left the grid")
        snapshot(app, "55-playlist-deleted")
    }

    func test11Devices() {
        let app = signInAsKid()

        for _ in 0..<7 {
            remote.press(.right)
            pause(1)
        }
        XCTAssertTrue(app.buttons["Switch Profile"].waitForExistence(timeout: 20))
        remote.press(.down)
        pause(1)
        moveFocus(.right, to: setting(app, "Video Quality"), limit: 3)
        XCTAssertTrue(moveFocus(.down, to: setting(app, "Devices"), limit: 8))
        remote.press(.select)
        let other = setting(app, "Kitchen iPad")
        XCTAssertTrue(other.waitForExistence(timeout: 20))
        XCTAssertTrue(setting(app, "Living Room Apple TV").exists, "this device is listed")
        pause(2)
        snapshot(app, "56-devices")

        XCTAssertTrue(moveFocus(.down, to: other, limit: 4))
        remote.press(.select)
        let signOut = menuItem(app, "Sign Out Device")
        XCTAssertTrue(signOut.waitForExistence(timeout: 10), hierarchy(app, mentioning: "Sign Out Device"))
        pause(1)
        snapshot(app, "57-device-sign-out")
        if moveFocus(.right, to: signOut, limit: 2) {
            remote.press(.select)
        }
        pause(3)
        XCTAssertFalse(other.exists, "the signed-out device left the list")
        snapshot(app, "58-device-signed-out")
    }

    /// The poster card whose title starts with `title`.
    private func card(_ app: XCUIApplication, _ title: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", title)).firstMatch
    }

    /// An item of a long-press menu or a confirmation dialog, whatever element type tvOS
    /// gives it.
    private func menuItem(_ app: XCUIApplication, _ label: String) -> XCUIElement {
        // tvOS context menu items are "Other" elements.
        let types = [XCUIElement.ElementType.button, .menuItem, .cell, .other].map(\.rawValue)
        return app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@ AND elementType IN %@", label, types))
            .firstMatch
    }

    /// The accessibility hierarchy lines that mention `text`, for failure messages.
    private func hierarchy(_ app: XCUIApplication, mentioning text: String) -> String {
        app.debugDescription.split(separator: "\n").filter { $0.contains(text) }.joined(separator: " | ")
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
