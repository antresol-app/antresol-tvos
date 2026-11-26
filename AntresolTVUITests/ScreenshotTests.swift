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
        // The first screen is set-up by phone; the address screen is one press away.
        XCTAssertTrue(app.staticTexts["Set up with your phone"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.buttons["Enter Address with the Remote"].exists)
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

        // Focus starts in the sidebar on Home; Right enters the hero, then on to Details.
        remote.press(.right)
        pause(2)
        XCTAssertTrue(moveFocus(.right, to: app.buttons["Details"], limit: 3))
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

        XCTAssertTrue(openSection(app, "Kiddo", showing: app.buttons["Switch Profile"]))
        XCTAssertTrue(app.buttons["Switch Profile"].waitForExistence(timeout: 20))
        pause(2)
        snapshot(app, "08-account")
    }

    func test03BrowseDetailsAndSearch() {
        let app = signInAsKid()

        XCTAssertTrue(openSection(app, "Movies", showing: app.buttons["Recently Added"]))
        pause(2)
        snapshot(app, "09-movies")

        // Focus starts on the sort pill: down into the grid, left to the first poster.
        remote.press(.down)
        pause(1)
        XCTAssertTrue(moveFocus(.left, to: card(app, "Big Buck Demo"), limit: 6))
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

        // TV Shows, then the show's page.
        XCTAssertTrue(openSection(app, "Shows", showing: card(app, "Test Show")))
        pause(2)
        snapshot(app, "12-shows")
        XCTAssertTrue(moveFocus(.down, to: card(app, "Test Show"), limit: 3))
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
        pause(2)

        // Search: Browse tiles, then results. Selecting it moves focus into the keyboard.
        XCTAssertTrue(openSection(app, "Search", showing: app.searchFields.firstMatch))
        pause(3)
        snapshot(app, "16-search")
        app.searchFields.firstMatch.typeText("test")
        pause(4)
        remote.press(.down)
        pause(2)
        snapshot(app, "17-search-results")
    }

    func test04Player() {
        // English subtitles preferred, so the side-loaded overlay shows from the start.
        let app = signInAsKid(extraArguments: ["-player.subtitleLanguage", "en"])

        // Sidebar → hero buttons → first Continue Watching card (a movie with progress).
        remote.press(.right)
        pause(2)
        XCTAssertTrue(moveFocus(.down, to: card(app, "Big Buck Demo"), limit: 2))
        pause(1)
        remote.press(.select)
        XCTAssertTrue(app.buttons["Start Over"].waitForExistence(timeout: 20))
        pause(3)
        // one line over the two buttons, as wide as they are: the bar from the first button's left edge (it is a little
        // bigger focused), the time left ending at the right edge of the second
        let bar = app.descendants(matching: .any).matching(identifier: "resume.progress").firstMatch
        let left = app.staticTexts["resume.remaining"]
        XCTAssertTrue(bar.exists && left.exists, "no progress line on the resume prompt")
        // (a button's own frame is its label: the pill reaches 44 points further on each side)
        XCTAssertEqual(left.frame.maxX, app.buttons["Start Over"].frame.maxX + 44, accuracy: 6, "the time left does not end where the buttons do")
        XCTAssertEqual(bar.frame.minX, app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Resume from")).firstMatch.frame.minX - 44, accuracy: 25, "the bar does not start where the buttons do")
        XCTAssertLessThan(bar.frame.maxX, left.frame.minX)
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
        remote.press(.right)
        pause(2)
        XCTAssertTrue(moveFocus(.down, to: card(app, "Big Buck Demo"), limit: 2))
        XCTAssertTrue(moveFocus(.right, to: card(app, "Episode 1"), limit: 3))
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

        XCTAssertTrue(openSection(app, "Music", showing: app.buttons["Listen Now"]))
        // The section pill remembers the last section (another test may have left one).
        if !app.buttons["Shuffle All"].waitForExistence(timeout: 5) {
            XCTAssertTrue(moveFocus(.up, to: app.buttons["Listen Now"], limit: 3))
            remote.press(.select)
        }
        XCTAssertTrue(app.buttons["Shuffle All"].waitForExistence(timeout: 20))
        pause(3)
        snapshot(app, "25-music-listen-now")

        // The first album of the first shelf (it has the song with lyrics). Down from the
        // section pill lands on the shelf's nearest card; Left walks back to the first.
        let album = card(app, "Sample Record")
        if !moveFocus(.down, to: album, limit: 2) {
            XCTAssertTrue(moveFocus(.left, to: album, limit: 4), "focus: \(focusedLabel(app))")
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
        // Up reaches the Up Next / Lyrics pill (on either option), then Lyrics.
        for _ in 0..<3 where !(app.buttons["Up Next"].hasFocus || app.buttons["Lyrics"].hasFocus) {
            remote.press(.up)
            pause(1)
        }
        XCTAssertTrue(moveFocus(.right, to: app.buttons["Lyrics"], limit: 2))
        remote.press(.select)
        pause(3)
        snapshot(app, "29-now-playing-lyrics")

        // Close Now Playing and the album, then the Albums section.
        remote.press(.menu)
        pause(2)
        remote.press(.menu)
        pause(2)
        XCTAssertTrue(moveFocus(.up, to: app.buttons["Listen Now"], limit: 6))
        XCTAssertTrue(moveFocus(.right, to: app.buttons["Albums"], limit: 2))
        remote.press(.select)
        pause(3)
        snapshot(app, "30-music-albums")
    }

    func test08Settings() {
        let app = signInAsKid()

        // The profile is the sidebar's last entry.
        XCTAssertTrue(openSection(app, "Kiddo", showing: app.buttons["Switch Profile"]))
        XCTAssertTrue(app.buttons["Switch Profile"].waitForExistence(timeout: 20))
        pause(2)
        snapshot(app, "37-settings")

        // Into the settings list, then the Interface Language page.
        remote.press(.down)
        pause(1)
        moveFocus(.right, to: setting(app, "Video Quality"), limit: 3)
        XCTAssertTrue(moveFocus(.down, to: setting(app, "Interface Language"), limit: 6))
        remote.press(.select)
        pause(3)
        snapshot(app, "38-settings-language")
        remote.press(.menu)
        pause(2)

        XCTAssertTrue(moveFocus(.down, to: setting(app, "Acknowledgements"), limit: 8))
        pause(1)
        snapshot(app, "39-settings-about")
        // The server is the web app's business: no address, devices or server change here.
        for title in ["Address", "Version", "Devices", "Change Server"] {
            XCTAssertFalse(setting(app, title).exists, title)
        }
        // A kid's separate history is an administrator's to change.
        XCTAssertFalse(setting(app, "Separate History").exists, "a kid has no separate-history row")
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
        // The linked page takes the focus from the sidebar, so Menu goes back to Home.
        let resume = app.buttons["Продолжить"]
        XCTAssertTrue(resume.waitForExistence(timeout: 10))
        let focused = expectation(for: NSPredicate(format: "hasFocus == true"), evaluatedWith: resume)
        wait(for: [focused], timeout: 15)
        XCTAssertTrue(resume.hasFocus, "The linked page should start on Resume")
        remote.press(.menu)
        pause(3)
        snapshot(app, "43-home-ru")
        XCTAssertTrue(openSection(app, "Kiddo", showing: app.buttons["Сменить профиль"]))
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

        // Music, then the Playlists section of the pill.
        XCTAssertTrue(openSection(app, "Music", showing: app.buttons["Listen Now"]))
        // The section pill remembers the last section (another test may have left Albums).
        XCTAssertTrue(app.buttons["Listen Now"].waitForExistence(timeout: 20))
        XCTAssertTrue(moveFocus(.up, to: app.buttons["Listen Now"], limit: 3))
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
        // Play Next, Add to Queue, Add to Playlist…, Add to Favorites, Move Down…
        chooseMenuItem(at: 4)
        pause(3)
        snapshot(app, "51-playlist-reordered")

        // Add the focused song to the new playlist.
        remote.press(.select, forDuration: 1.5)
        let addToPlaylist = menuItem(app, "Add to Playlist…")
        XCTAssertTrue(addToPlaylist.waitForExistence(timeout: 10))
        chooseMenuItem(at: 2)
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
        // Rename, Delete Playlist.
        chooseMenuItem(at: 1)
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

    /// A show's full episode list: downloaded episodes as before, one not downloaded
    /// (selecting it only says so) and upcoming ones greyed with their date.
    func test12EpisodeGuide() {
        let app = signInAsKid()

        XCTAssertTrue(openSection(app, "Shows", showing: card(app, "Test Show")))
        pause(2)
        XCTAssertTrue(moveFocus(.down, to: card(app, "Test Show"), limit: 3))
        remote.press(.select)
        pause(4)
        // The first episode by name: the row's elements are not listed left to right, and
        // the cast row below takes the focus of a Down that is one too many.
        let downloaded = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@ AND label CONTAINS %@", "Episode 1", "Downloaded")).firstMatch
        let missing = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Not downloaded")).firstMatch
        let upcoming = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Airs ")).firstMatch
        XCTAssertTrue(missing.waitForExistence(timeout: 20), hierarchy(app, mentioning: "E3"))
        XCTAssertTrue(downloaded.exists)
        XCTAssertTrue(upcoming.exists)

        XCTAssertTrue(moveFocus(.down, to: downloaded, limit: 3))
        pause(1)
        snapshot(app, "59-episode-guide")
        XCTAssertTrue(moveFocus(.right, to: missing, limit: 3))
        remote.press(.select)
        XCTAssertTrue(app.staticTexts["Not in the library"].waitForExistence(timeout: 5))
        pause(1)
        snapshot(app, "60-episode-not-downloaded")
        XCTAssertTrue(moveFocus(.right, to: upcoming, limit: 2))
        pause(1)
        snapshot(app, "61-episode-upcoming")
        // The last one has no date yet; the lazy row lays it out once scrolled near it.
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Upcoming")).firstMatch.exists, "no date yet")

        // A downloaded episode still opens its page.
        XCTAssertTrue(moveFocus(.left, to: downloaded, limit: 4))
        remote.press(.select)
        XCTAssertTrue(app.buttons["Go to Show"].waitForExistence(timeout: 20), "the episode page")
    }

    /// Continue Watching: a long press offers the details page (a movie's, an episode's);
    /// a click still resumes.
    func test13ContinueWatchingLongPress() {
        let app = signInAsKid()
        remote.press(.right)
        pause(2)
        let movie = card(app, "Big Buck Demo")
        XCTAssertTrue(moveFocus(.down, to: movie, limit: 2))
        remote.press(.select, forDuration: 1.6)
        XCTAssertTrue(menuItem(app, "Play from Beginning").waitForExistence(timeout: 10), hierarchy(app, mentioning: "Beginning"))
        pause(1)
        snapshot(app, "62-continue-long-press")
        chooseMenuItem(at: 0)
        XCTAssertTrue(app.buttons["Watchlist"].waitForExistence(timeout: 20), "the movie's page")
        pause(3)
        snapshot(app, "63-continue-details-movie")
        remote.press(.menu)
        pause(2)

        // The episode in Continue Watching shows its own still. (Back from a page, focus
        // lands on the hero.)
        XCTAssertTrue(moveFocus(.down, to: movie, limit: 2), focusedLabel(app))
        let episode = card(app, "Episode 1")
        XCTAssertTrue(moveFocus(.right, to: episode, limit: 3), focusedLabel(app))
        pause(2)
        snapshot(app, "64-continue-episode-still")
        remote.press(.select, forDuration: 1.6)
        XCTAssertTrue(menuItem(app, "Play from Beginning").waitForExistence(timeout: 10))
        chooseMenuItem(at: 0)
        XCTAssertTrue(app.buttons["Go to Show"].waitForExistence(timeout: 20), "the episode's page")
        pause(3)
        snapshot(app, "65-continue-details-episode")
        remote.press(.menu)
        pause(2)

        // A plain click resumes (the resume prompt).
        if !moveFocus(.down, to: movie, limit: 2) {
            moveFocus(.left, to: movie, limit: 3)
        }
        XCTAssertTrue(movie.hasFocus, focusedLabel(app))
        remote.press(.select)
        XCTAssertTrue(app.buttons["Start Over"].waitForExistence(timeout: 20))
        remote.press(.menu)
        pause(2)
    }

    /// Watched marks on posters and episodes, episode stills, cast portraits and trailers:
    /// the movie's trailer plays in the app (the mock is busy once, then slow), the series'
    /// teaser fails (the error with Try Again), and a trailer without `play` falls back to
    /// the QR code (no YouTube app on the simulator).
    func test14WatchedStillsCastTrailers() {
        let app = signInAsKid()

        XCTAssertTrue(openSection(app, "Movies", showing: app.buttons["Recently Added"]))
        pause(3)
        snapshot(app, "66-movies-watched")

        remote.press(.down)
        pause(1)
        XCTAssertTrue(moveFocus(.left, to: card(app, "Big Buck Demo"), limit: 6), focusedLabel(app))
        remote.press(.select)
        let trailer = app.buttons["Trailer"]
        XCTAssertTrue(trailer.waitForExistence(timeout: 20))
        pause(2)
        XCTAssertTrue(moveFocus(.right, to: trailer, limit: 4), focusedLabel(app))
        pause(1)
        snapshot(app, "67-movie-trailer-button")
        // One trailer: the player opens at once, loading while the server gets it ready.
        remote.press(.select)
        XCTAssertTrue(app.staticTexts["Official Trailer"].waitForExistence(timeout: 5), hierarchy(app, mentioning: "Trailer"))
        pause(1)
        snapshot(app, "68-trailer-loading")
        XCTAssertTrue(app.staticTexts["Official Trailer"].waitForNonExistence(timeout: 20), "the trailer starts")
        XCTAssertFalse(app.staticTexts["Open on Your Phone"].exists, "no QR code for a trailer the server plays")
        pause(4)
        snapshot(app, "68b-trailer-playing")
        // The transport bar is hidden by now: one Menu closes the player.
        remote.press(.menu)
        pause(3)
        XCTAssertTrue(trailer.waitForExistence(timeout: 10), "Menu closes the trailer")
        for _ in 0..<2 {
            remote.press(.down)
            pause(1)
        }
        pause(2)
        snapshot(app, "69-movie-cast")
        remote.press(.menu)
        pause(2)

        XCTAssertTrue(openSection(app, "Shows", showing: card(app, "Test Show")))
        XCTAssertTrue(moveFocus(.down, to: card(app, "Test Show"), limit: 3))
        remote.press(.select)
        XCTAssertTrue(trailer.waitForExistence(timeout: 20))
        pause(2)
        XCTAssertTrue(moveFocus(.right, to: trailer, limit: 4), focusedLabel(app))
        // Several trailers: the chooser.
        remote.press(.select)
        XCTAssertTrue(menuItem(app, "Season 2 Teaser").waitForExistence(timeout: 10), hierarchy(app, mentioning: "Teaser"))
        pause(1)
        snapshot(app, "70-trailer-chooser")
        // The teaser's fetch fails on the server: the error, and Try Again asks again.
        chooseMenuItem(at: 1)
        let tryAgain = app.buttons["Try Again"]
        XCTAssertTrue(tryAgain.waitForExistence(timeout: 20), hierarchy(app, mentioning: "Teaser"))
        pause(2)
        snapshot(app, "71-trailer-error")
        XCTAssertTrue(tryAgain.hasFocus, focusedLabel(app))
        remote.press(.select)
        XCTAssertTrue(app.staticTexts["Season 2 Teaser"].waitForExistence(timeout: 5), "loading again")
        XCTAssertTrue(tryAgain.waitForExistence(timeout: 20))
        pause(1)
        remote.press(.menu)
        pause(2)
        XCTAssertTrue(trailer.waitForExistence(timeout: 10), "Menu closes the error")
        XCTAssertTrue(moveFocus(.right, to: trailer, limit: 4), focusedLabel(app))
        // A trailer the server does not play (an older server): the QR code.
        remote.press(.select)
        XCTAssertTrue(menuItem(app, "Behind the Scenes").waitForExistence(timeout: 10), hierarchy(app, mentioning: "Behind"))
        chooseMenuItem(at: 2)
        XCTAssertTrue(app.staticTexts["Open on Your Phone"].waitForExistence(timeout: 10))
        pause(2)
        snapshot(app, "71b-trailer-qr-fallback")
        remote.press(.menu)
        pause(2)

        let firstEpisode = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Episode 1")).firstMatch
        XCTAssertTrue(moveFocus(.down, to: firstEpisode, limit: 3), focusedLabel(app))
        pause(2)
        snapshot(app, "72-episodes-stills-watched")
        XCTAssertTrue(moveFocus(.right, to: app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Episode 2")).firstMatch, limit: 2))
        pause(2)
        snapshot(app, "72b-episode-still-focused")
        for _ in 0..<2 {
            remote.press(.down)
            pause(1)
        }
        pause(2)
        snapshot(app, "73-series-cast")
    }

    /// The Movies grid: equal margins, and rows scrolled up stay below the title and the
    /// sidebar's chip.
    func test18GridMarginsAndScrolling() {
        let app = signInAsKid()
        XCTAssertTrue(openSection(app, "Movies", showing: app.buttons["Recently Added"]))
        pause(3)
        snapshot(app, "78-movies-grid")
        for _ in 0..<3 {
            remote.press(.down)
            pause(1)
        }
        pause(2)
        snapshot(app, "79-movies-scrolled")
        XCTAssertTrue(openSection(app, "Shows", showing: card(app, "Test Show")))
        pause(2)
        snapshot(app, "80-shows-grid")
    }

    /// A tab left on a pushed page goes back to its root after five seconds away.
    func test15TabResetAfterFiveSeconds() {
        let app = signInAsKid()
        XCTAssertTrue(openSection(app, "Movies", showing: app.buttons["Recently Added"]))
        remote.press(.down)
        pause(1)
        XCTAssertTrue(moveFocus(.left, to: card(app, "Big Buck Demo"), limit: 6))
        remote.press(.select)
        XCTAssertTrue(app.buttons["Watchlist"].waitForExistence(timeout: 20))
        pause(2)

        XCTAssertTrue(openSection(app, "Shows", showing: card(app, "Test Show")))
        pause(8)
        XCTAssertTrue(openSection(app, "Movies", showing: app.buttons["Recently Added"]), "Movies is back at its grid")
        XCTAssertFalse(app.buttons["Watchlist"].exists, "the movie page was popped")
        pause(1)
        snapshot(app, "74-tab-reset")
    }

    /// Coming back before the delay keeps the page (the delay is stretched so the walk
    /// through the sidebar fits in it).
    func test16TabKeptWhenBackQuickly() {
        let app = signInAsKid(extraArguments: ["-AntresolTabResetSeconds", "40"])
        XCTAssertTrue(openSection(app, "Movies", showing: app.buttons["Recently Added"]))
        remote.press(.down)
        pause(1)
        XCTAssertTrue(moveFocus(.left, to: card(app, "Big Buck Demo"), limit: 6))
        remote.press(.select)
        XCTAssertTrue(app.buttons["Watchlist"].waitForExistence(timeout: 20))
        pause(2)
        let started = Date()
        XCTAssertTrue(openSection(app, "Shows", showing: card(app, "Test Show")))
        XCTAssertTrue(openSection(app, "Movies", showing: app.buttons["Watchlist"]), "the movie page is still there")
        print("Round trip through the sidebar: \(Int(Date().timeIntervalSince(started))) s")
        snapshot(app, "75-tab-kept")
    }

    /// Entering and leaving the same show and movie ten times stays responsive (Android TV
    /// froze doing this).
    func test17RepeatedEnterAndLeave() {
        let app = signInAsKid()
        XCTAssertTrue(openSection(app, "Shows", showing: card(app, "Test Show")))
        let show = card(app, "Test Show")
        XCTAssertTrue(moveFocus(.down, to: show, limit: 3))
        let watchlist = app.buttons["Watchlist"]
        for round in 1...10 {
            let started = Date()
            remote.press(.select)
            XCTAssertTrue(watchlist.waitForExistence(timeout: 10), "show, round \(round)")
            print("Show page \(round): \(String(format: "%.1f", Date().timeIntervalSince(started))) s")
            remote.press(.menu)
            XCTAssertTrue(show.waitForExistence(timeout: 10))
            let focused = expectation(for: NSPredicate(format: "hasFocus == true"), evaluatedWith: show)
            wait(for: [focused], timeout: 10)
        }
        snapshot(app, "76-show-after-ten-visits")

        XCTAssertTrue(openSection(app, "Movies", showing: app.buttons["Recently Added"]))
        remote.press(.down)
        pause(1)
        let movie = card(app, "Big Buck Demo")
        XCTAssertTrue(moveFocus(.left, to: movie, limit: 6))
        for round in 1...10 {
            let started = Date()
            remote.press(.select)
            XCTAssertTrue(watchlist.waitForExistence(timeout: 10), "movie, round \(round)")
            print("Movie page \(round): \(String(format: "%.1f", Date().timeIntervalSince(started))) s")
            remote.press(.menu)
            let focused = expectation(for: NSPredicate(format: "hasFocus == true"), evaluatedWith: movie)
            wait(for: [focused], timeout: 10)
        }
        remote.press(.select)
        XCTAssertTrue(watchlist.waitForExistence(timeout: 10))
        pause(2)
        snapshot(app, "77-movie-after-ten-visits")
    }

    /// The poster card whose title starts with `title`.
    private func card(_ app: XCUIApplication, _ title: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", title)).firstMatch
    }

    /// Selects the long-press menu item at `index`. Menu items do not report focus to
    /// XCTest, so this counts presses from the first item, where the menu opens.
    private func chooseMenuItem(at index: Int) {
        pause(1)
        for _ in 0..<index {
            remote.press(.down)
            pause(1)
        }
        remote.press(.select)
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

    /// Opens a section from the sidebar: Left until the sidebar has focus, then up or down
    /// to its entry and select. Entries are the full-width rows at the screen's left edge
    /// (the profile's starts with its name).
    /// The system sidebar hands the focus to the content after a few idle seconds (right
    /// after sign-in it starts on Home), so the walk goes back into it whenever it left.
    /// Returns whether `marker`, an element only that section shows, appeared.
    @discardableResult
    private func openSection(_ app: XCUIApplication, _ title: String, showing marker: XCUIElement) -> Bool {
        let focused = app.descendants(matching: .any).element(matching: NSPredicate(format: "hasFocus == true"))
        // An entry row, not the sidebar itself (focused while it opens).
        func inSidebar() -> Bool {
            guard focused.exists else { return false }
            let frame = focused.frame
            return frame.minX < 1 && frame.width < 600 && frame.height < 150
        }
        func enterSidebar() -> Bool {
            for _ in 0..<6 where !inSidebar() {
                remote.press(.left)
                pause(1)
            }
            return inSidebar()
        }
        // From the focused row to the entry; nil when the sidebar collapsed meanwhile (it
        // then has no entry rows) and the next try goes back into it.
        func entryDelta() -> CGFloat? {
            guard enterSidebar() else { return nil }
            let candidates = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", title)).allElementsBoundByIndex
            guard let entry = candidates.first(where: { $0.frame.minX < 1 && $0.frame.width < 600 }),
                  inSidebar()
            else { return nil }
            return entry.frame.midY - focused.frame.midY
        }
        for _ in 0..<12 {
            guard let delta = entryDelta() else { continue }
            if abs(delta) < 4 { break }
            remote.press(delta > 0 ? .down : .up)
            pause(1)
        }
        guard let delta = entryDelta(), abs(delta) < 4 else { return false }
        remote.press(.select)
        guard marker.waitForExistence(timeout: 15) else { return false }
        pause(2)
        return true
    }

    /// The focused element's label, for failure messages.
    private func focusedLabel(_ app: XCUIApplication) -> String {
        let focused = app.descendants(matching: .any).element(matching: NSPredicate(format: "hasFocus == true"))
        return focused.exists ? "\(focused.label) \(focused.frame)" : "none"
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
