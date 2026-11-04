import Foundation
import XCTest
@testable import AntresolKit
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Runs against a live server when `ANTRESOL_TEST_SERVER` is set (`1` for
/// http://127.0.0.1:8420, or a server address). Credentials default to the sample
/// server's admin: `ANTRESOL_TEST_USER` (1) and `ANTRESOL_TEST_PASSWORD` (admin123).
/// The tests only read, except for changes they revert (progress, watchlist, star,
/// a temporary playlist) and a device token for a fixed test device id.
enum LiveServer {
    static var baseURL: URL? {
        guard let value = ProcessInfo.processInfo.environment["ANTRESOL_TEST_SERVER"], !value.isEmpty else { return nil }
        return value == "1" ? URL(string: "http://127.0.0.1:8420") : ServerAddress.normalize(value)
    }

    static let session = SignedInSession()

    actor SignedInSession {
        private var client: APIClient?

        func client(_ baseURL: URL) async throws -> APIClient {
            if let client { return client }
            let env = ProcessInfo.processInfo.environment
            let client = APIClient(baseURL: baseURL, language: "en")
            let device = DeviceInfo(id: "antresolkit-integration-tests", name: "AntresolKit tests", model: "CI", version: "1.0")
            try await client.signIn(
                userId: Int(env["ANTRESOL_TEST_USER"] ?? "") ?? 1,
                password: env["ANTRESOL_TEST_PASSWORD"] ?? "admin123",
                device: device
            )
            self.client = client
            return client
        }
    }

    /// Fetches a URL with no auth headers at all, like AVPlayer would.
    static func rawGet(_ url: URL, range: String? = "bytes=0-1023") async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        if let range { request.setValue(range, forHTTPHeaderField: "Range") }
        return try await URLSessionTransport().send(request)
    }
}

final class IntegrationTests: XCTestCase {
    private func client() async throws -> APIClient {
        guard let url = LiveServer.baseURL else {
            throw XCTSkip("Set ANTRESOL_TEST_SERVER to run integration tests")
        }
        return try await LiveServer.session.client(url)
    }

    func testPublicEndpoints() async throws {
        let client = try await client()
        let anonymous = APIClient(baseURL: client.baseURL)
        let health = try await anonymous.health()
        XCTAssertTrue(health.ok)
        XCTAssertEqual(health.serverId.count, 32)
        let setup = try await anonymous.setupStatus()
        XCTAssertFalse(setup.needsSetup)
        let profiles = try await anonymous.profiles()
        XCTAssertFalse(profiles.isEmpty)

        do {
            _ = try await anonymous.me()
            XCTFail("expected 401 without a token")
        } catch let error as APIError {
            XCTAssertEqual(error.statusCode, 401)
        }
    }

    func testAccount() async throws {
        let client = try await client()
        let me = try await client.me()
        XCTAssertTrue(me.isAdmin)
        let devices = try await client.devices()
        XCTAssertTrue(devices.contains { $0.current && $0.name == "AntresolKit tests" })
        let key = try await client.mediaKey()
        XCTAssertTrue(key.key.hasPrefix("v1."))
        XCTAssertGreaterThan(key.expiryDate?.timeIntervalSinceNow ?? 0, 11 * 3600)
        _ = try await client.libraryStatus()
    }

    func testLibraryBrowsing() async throws {
        let client = try await client()
        let home = try await client.home()
        XCTAssertTrue(home.shelves.contains { $0.id == ShelfID.continueWatching })

        let movies = try await client.items(kind: .movie, sort: .title)
        XCTAssertFalse(movies.items.isEmpty)
        XCTAssertEqual(movies.items.map(\.title), movies.items.map(\.title).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending })
        let firstPage = try await client.items(kind: .movie, limit: 1)
        XCTAssertEqual(firstPage.items.count, 1)
        XCTAssertEqual(firstPage.hasMore(after: 0), firstPage.total > 1)

        for card in movies.items {
            let detail = try await client.item(id: card.id)
            XCTAssertEqual(detail.id, card.id)
            XCTAssertEqual(detail.kind, .movie)
            XCTAssertFalse(detail.files.isEmpty, card.title)
        }

        let series = try await client.items(kind: .series)
        for card in series.items {
            let detail = try await client.item(id: card.id)
            XCTAssertFalse(detail.seasons.isEmpty)
            for season in detail.seasons {
                let seasonDetail = try await client.item(id: season.id)
                XCTAssertEqual(seasonDetail.seasons.first?.id, season.id)
                for episode in season.episodes {
                    let episodeDetail = try await client.item(id: episode.id)
                    XCTAssertEqual(episodeDetail.kind, .episode)
                    XCTAssertNotNil(episodeDetail.primaryFile)
                }
            }
        }

        let query = String(movies.items[0].title.prefix(4))
        let results = try await client.search(query)
        XCTAssertTrue(results.library.contains { $0.id == movies.items[0].id })
        let empty = try await client.search("")
        XCTAssertTrue(empty.isEmpty)
    }

    func testImagesNeedBearer() async throws {
        let client = try await client()
        let movies = try await client.items(kind: .movie)
        let card = try XCTUnwrap(movies.items.first { !$0.poster.isEmpty })
        let data = try await client.data(path: card.poster)
        XCTAssertGreaterThan(data.count, 100)
        let url = try XCTUnwrap(client.urls.image(card.poster))
        let (_, response) = try await LiveServer.rawGet(url, range: nil)
        XCTAssertEqual(response.statusCode, 401)
    }

    func testVideoPlayback() async throws {
        let client = try await client()
        let keys = MediaKeyStore(client: client)
        let movies = try await client.items(kind: .movie).items
        var modes: Set<PlaybackMode> = []
        for card in movies {
            let detail = try await client.item(id: card.id)
            let file = try XCTUnwrap(detail.primaryFile)
            let session = VideoPlaybackSession(client: client, mediaKeys: keys, fileId: file.id)
            let source = try await session.start(at: 0)
            modes.insert(source.mode)
            XCTAssertGreaterThan(source.response.durationMs, 0)
            if source.mode.isHLS {
                let sessionID = try XCTUnwrap(source.hlsSessionID)
                let (data, response) = try await LiveServer.rawGet(source.url, range: nil)
                XCTAssertEqual(response.statusCode, 200)
                let playlist = String(decoding: data, as: UTF8.self)
                XCTAssertTrue(playlist.hasPrefix("#EXTM3U"))
                if source.response.hlsComplete {
                    XCTAssertTrue(playlist.contains("#EXT-X-PLAYLIST-TYPE:VOD"))
                    XCTAssertTrue(playlist.contains("mk="), "segment URIs are signed")
                }
                let status = try await client.keepAlive(hlsSession: sessionID)
                XCTAssertGreaterThanOrEqual(status.segments, 0)

                // Seek: replaces the session instead of opening another one.
                let replaced = try await session.start(at: 10)
                XCTAssertNotEqual(replaced.hlsSessionID, sessionID)
                XCTAssertLessThanOrEqual(replaced.timelineOffset, 10)
                do {
                    try await client.keepAlive(hlsSession: sessionID)
                    XCTFail("replaced session should be gone")
                } catch let error as APIError {
                    XCTAssertTrue(error.isNotFound)
                }
            } else {
                let (_, response) = try await LiveServer.rawGet(source.url)
                XCTAssertEqual(response.statusCode, 206, "direct stream honours Range with the media key")
            }
            await session.stop()
        }
        XCTAssertTrue(modes.contains(.direct))
        XCTAssertTrue(modes.contains { $0.isHLS })
    }

    /// A resume in the middle of an HLS file still gets the whole timeline (VOD playlist
    /// from 0), and a segment far into it is produced on demand.
    func testHLSResumeKeepsFullTimeline() async throws {
        let client = try await client()
        let keys = MediaKeyStore(client: client)
        for card in try await client.items(kind: .movie).items {
            let detail = try await client.item(id: card.id)
            guard let file = detail.primaryFile, file.name.lowercased().hasSuffix(".mkv") else { continue }
            let session = VideoPlaybackSession(client: client, mediaKeys: keys, fileId: file.id)
            let position = Double(file.durationMs ?? 0) / 2000
            let source = try await session.start(at: position)
            XCTAssertTrue(source.mode.isHLS, "AVPlayer cannot open MKV; expected HLS")
            XCTAssertTrue(source.response.hlsComplete)
            XCTAssertEqual(source.timelineOffset, 0)
            XCTAssertEqual(source.initialPlayerSeek, position, accuracy: 0.001)
            let (data, _) = try await LiveServer.rawGet(source.url, range: nil)
            let segments = String(decoding: data, as: UTF8.self).split(separator: "\n").filter { !$0.hasPrefix("#") && !$0.isEmpty }
            let middle = try XCTUnwrap(source.url.deletingLastPathComponent()
                .appendingPathComponent(String(segments[segments.count / 2].split(separator: "?")[0])))
            var components = try XCTUnwrap(URLComponents(url: middle, resolvingAgainstBaseURL: false))
            components.query = source.url.query
            let (_, response) = try await LiveServer.rawGet(try XCTUnwrap(components.url), range: nil)
            XCTAssertEqual(response.statusCode, 200)
            await session.stop()
            return
        }
        throw XCTSkip("No MKV movie on the test server")
    }

    func testSubtitles() async throws {
        let client = try await client()
        let movies = try await client.items(kind: .movie).items
        var checked = 0
        for card in movies {
            let detail = try await client.item(id: card.id)
            for track in detail.files.flatMap(\.subs) where track.isText {
                let cues = try await client.subtitleCues(path: try XCTUnwrap(track.url))
                XCTAssertFalse(cues.isEmpty, "\(card.title) subtitle \(track.index)")
                checked += 1
            }
        }
        XCTAssertGreaterThan(checked, 0)
    }

    func testProgressRoundTrip() async throws {
        let client = try await client()
        let movies = try await client.items(kind: .movie).items
        let movie = try XCTUnwrap(movies.first)
        let original = try await client.progress(itemId: movie.id)
        let detail = try await client.item(id: movie.id)
        let duration = try XCTUnwrap(detail.primaryFile?.durationMs)
        let reporter = ProgressReporter(client: client, itemId: movie.id)
        await reporter.update(positionMs: 4321, durationMs: duration)
        await reporter.flush()
        let stored = try await client.progress(itemId: movie.id)
        XCTAssertEqual(stored.positionMs, 4321)
        XCTAssertEqual(stored.durationMs, duration)
        XCTAssertFalse(stored.finished)

        if original.finished {
            try await client.setWatched(itemId: movie.id, true)
        } else if original.exists {
            try await client.updateProgress(itemId: movie.id, .media(positionMs: original.positionMs, durationMs: original.durationMs))
        } else {
            try await client.setWatched(itemId: movie.id, false)
        }
        let restored = try await client.progress(itemId: movie.id)
        XCTAssertEqual(restored.finished, original.finished)
        XCTAssertEqual(restored.exists, original.exists)
    }

    func testWatchlistToggle() async throws {
        let client = try await client()
        let candidates = try await client.items(kind: nil).items
        var target: ItemDetail?
        for card in candidates {
            let detail = try await client.item(id: card.id)
            if !detail.inWatchlist { target = detail; break }
        }
        let item = try XCTUnwrap(target, "needs an item outside the watchlist")
        try await client.setInWatchlist(itemId: item.id, true)
        let added = try await client.item(id: item.id).inWatchlist
        try await client.setInWatchlist(itemId: item.id, false)
        let removed = try await client.item(id: item.id).inWatchlist
        XCTAssertTrue(added)
        XCTAssertFalse(removed)
    }

    func testMusic() async throws {
        let client = try await client()
        let home = try await client.musicHome()
        XCTAssertFalse(home.shelves.isEmpty)
        for sort in AlbumSort.allCases {
            _ = try await client.albums(sort: sort)
        }
        let albums = try await client.albums()
        XCTAssertFalse(albums.items.isEmpty)
        var lyricsChecked = false
        for card in albums.items {
            let album = try await client.album(id: card.id)
            XCTAssertEqual(album.card.id, card.id)
            XCTAssertFalse(album.tracks.isEmpty)
            for track in album.tracks {
                let lyrics = try await client.lyrics(trackId: track.id)
                XCTAssertEqual(lyrics != nil, track.hasLyrics, track.title)
                lyricsChecked = lyricsChecked || lyrics != nil
            }
        }
        XCTAssertTrue(lyricsChecked)

        let artists = try await client.artists()
        let artistCard = try XCTUnwrap(artists.items.first)
        let artist = try await client.artist(id: artistCard.id)
        XCTAssertFalse(artist.albums.isEmpty)
        let byArtist = try await client.albums(artistId: artistCard.id)
        XCTAssertFalse(byArtist.items.isEmpty)

        let songs = try await client.songs()
        let song = try XCTUnwrap(songs.items.first)
        let track = try await client.track(id: song.id)
        XCTAssertEqual(track.fileId, song.fileId)

        let genres = try await client.genres()
        if let genre = genres.first {
            let genreAlbums = try await client.albums(genre: genre.name)
            XCTAssertEqual(genreAlbums.items.count, genre.albums)
            _ = try await client.shuffle(.genre(genre.name))
        }
        let shuffled = try await client.shuffle()
        XCTAssertFalse(shuffled.isEmpty)
        _ = try await client.shuffle(.artist(artistCard.id))

        let key = try await MediaKeyStore(client: client).key()
        let streamURL = try XCTUnwrap(client.urls.trackStream(trackId: song.id, mediaKey: key))
        let (_, response) = try await LiveServer.rawGet(streamURL)
        XCTAssertTrue([200, 206].contains(response.statusCode))

        // Star and unstar the track, restoring its state.
        try await client.setStarred(itemId: song.id, !song.starred)
        let toggled = try await client.track(id: song.id).starred
        try await client.setStarred(itemId: song.id, song.starred)
        let restored = try await client.track(id: song.id).starred
        XCTAssertEqual(toggled, !song.starred)
        XCTAssertEqual(restored, song.starred)

        // A temporary playlist.
        let created = try await client.createPlaylist(name: "AntresolKit test", trackIds: [song.id])
        do {
            XCTAssertEqual(created.trackCount, 1)
            let updated = try await client.updatePlaylist(id: created.id, PlaylistUpdate(name: "AntresolKit test 2", append: [song.id]))
            XCTAssertEqual(updated.name, "AntresolKit test 2")
            XCTAssertEqual(updated.trackCount, 2)
            let detail = try await client.playlist(id: created.id)
            XCTAssertEqual(detail.tracks.compactMap(\.idx), [0, 1])
            let lists = try await client.playlists()
            XCTAssertTrue(lists.contains { $0.id == created.id })
        } catch {
            try? await client.deletePlaylist(id: created.id)
            throw error
        }
        try await client.deletePlaylist(id: created.id)
        let afterDelete = try await client.playlists()
        XCTAssertFalse(afterDelete.contains { $0.id == created.id })
    }

    func testBooksAndComics() async throws {
        let client = try await client()
        let home = try await client.booksHome()
        XCTAssertFalse(home.shelves.isEmpty)
        for sort in BookSort.allCases {
            _ = try await client.books(kind: .audiobook, sort: sort)
        }
        let key = try await MediaKeyStore(client: client).key()

        let audiobooks = try await client.books(kind: .audiobook)
        XCTAssertFalse(audiobooks.items.isEmpty)
        for card in audiobooks.items {
            let book = try await client.book(id: card.id)
            XCTAssertEqual(book.kind, .audiobook)
            XCTAssertFalse(book.files.isEmpty)
            XCTAssertEqual(book.audiobookTimeline.totalMs, book.durationMs)
            XCTAssertFalse(book.chapters.isEmpty)
            let audioURL = try XCTUnwrap(client.urls.audio(fileId: book.files[0].id, mediaKey: key))
            let (_, response) = try await LiveServer.rawGet(audioURL)
            XCTAssertTrue([200, 206].contains(response.statusCode))
        }

        _ = try await client.books(kind: .book)

        let comics = try await client.books(kind: .comic)
        let series = try await client.book(id: try XCTUnwrap(comics.items.first?.id))
        let volume = try XCTUnwrap(series.volumes.first)
        let volumeDetail = try await client.book(id: volume.id)
        XCTAssertEqual(volumeDetail.readFileId, volume.fileId)
        let pages = try await client.comicPages(fileId: volume.fileId)
        XCTAssertEqual(pages.count, volume.pages)
        let page = try await client.comicPage(fileId: volume.fileId, index: 0)
        XCTAssertGreaterThan(page.count, 0)
    }
}
