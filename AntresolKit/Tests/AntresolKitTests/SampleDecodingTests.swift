import Foundation
import XCTest
@testable import AntresolKit

/// Decodes every response captured from a real 0.3.0 server.
final class SampleDecodingTests: XCTestCase {
    /// Sample file -> decoder. Every JSON sample must be listed here.
    static let decoders: [String: (Data) throws -> Any] = {
        func d<T: Decodable>(_ type: T.Type) -> (Data) throws -> Any {
            { try JSONDecoder().decode(T.self, from: $0) }
        }
        return [
            "auth-media-key.json": d(MediaKey.self),
            "auth-token.json": d(TokenResponse.self),
            "book-audiobook-mp3.json": d(BookDetail.self),
            "book-audiobook-multifile.json": d(BookDetail.self),
            "book-audiobook.json": d(BookDetail.self),
            "book-comic-volume.json": d(BookDetail.self),
            "book-comic.json": d(BookDetail.self),
            "books-audiobooks.json": d(Page<Card>.self),
            "books-comics.json": d(Page<Card>.self),
            "books-home.json": d(ShelvesResponse.self),
            "comic-pages.json": d(ComicPages.self),
            "error-401.json": d(ErrorBody.self),
            "health.json": d(ServerHealth.self),
            "hls-keepalive.json": d(HLSStatus.self),
            "home.json": d(HomeResponse.self),
            "item-episode.json": d(ItemDetail.self),
            "item-movie.json": d(ItemDetail.self),
            "item-season.json": d(ItemDetail.self),
            "item-series.json": d(ItemDetail.self),
            "items-movies.json": d(Page<Card>.self),
            "items-series.json": d(Page<Card>.self),
            "library-status.json": d(LibraryStatus.self),
            "me-devices.json": d(ItemsEnvelope<DeviceSession>.self),
            "me.json": d(User.self),
            "music-album.json": d(AlbumDetail.self),
            "music-albums.json": d(Page<Card>.self),
            "music-artist.json": d(ArtistDetail.self),
            "music-artists.json": d(Page<Card>.self),
            "music-genres.json": d(GenresResponse.self),
            "music-home.json": d(ShelvesResponse.self),
            "music-lyrics.json": d(Lyrics.self),
            "music-shuffle.json": d(ShuffleResponse.self),
            "music-songs.json": d(Page<Track>.self),
            "music-track.json": d(Track.self),
            "play-direct.json": d(PlayResponse.self),
            "play-hevc-fmp4.json": d(PlayResponse.self),
            "play-mkv-hls.json": d(PlayResponse.self),
            "play-transcode-pixfmt.json": d(PlayResponse.self),
            "play-transcode-quality.json": d(PlayResponse.self),
            "playlist-create.json": d(Playlist.self),
            "playlist-update.json": d(Playlist.self),
            "playlist.json": d(PlaylistDetail.self),
            "playlists.json": d(ItemsEnvelope<Playlist>.self),
            "profiles.json": d([Profile].self),
            "progress-get.json": d(PlaybackProgress.self),
            "search-music.json": d(SearchResults.self),
            "search.json": d(SearchResults.self),
            "setup-get.json": d(SetupStatus.self),
            "users-create.json": d(User.self),
            "users-list.json": d([User].self),
        ]
    }()

    func testEverySampleDecodes() throws {
        let names = Samples.allJSONNames
        XCTAssertFalse(names.isEmpty, "no samples bundled")
        for name in names {
            guard let decode = Self.decoders[name] else {
                XCTFail("No decoder registered for sample \(name)")
                continue
            }
            XCTAssertNoThrow(try decode(Samples.data(name)), name)
        }
    }

    func testAuth() throws {
        let token = try Samples.decode(TokenResponse.self, "auth-token.json")
        XCTAssertEqual(token.token.count, 43)
        XCTAssertEqual(token.user.name, "Admin")
        XCTAssertTrue(token.user.isAdmin)
        XCTAssertNil(token.user.maxRating)

        let profiles = try Samples.decode([Profile].self, "profiles.json")
        XCTAssertEqual(profiles.map(\.id), [1, 2])
        XCTAssertTrue(profiles[0].hasPassword)
        XCTAssertEqual(profiles[1].avatarPreset, .grad4)

        let users = try Samples.decode([User].self, "users-list.json")
        XCTAssertEqual(users[1].maxRating, "6+")
        XCTAssertTrue(users[1].isKid)

        let key = try Samples.decode(MediaKey.self, "auth-media-key.json")
        XCTAssertTrue(key.key.hasPrefix("v1."))
        XCTAssertNotNil(key.expiryDate)

        let health = try Samples.decode(ServerHealth.self, "health.json")
        XCTAssertTrue(health.ok)
        XCTAssertEqual(health.serverId.count, 32)

        let devices = try Samples.decode(ItemsEnvelope<DeviceSession>.self, "me-devices.json").items
        XCTAssertEqual(devices.filter(\.current).count, 1)
    }

    func testHome() throws {
        let home = try Samples.decode(HomeResponse.self, "home.json")
        XCTAssertFalse(home.hero.isEmpty)
        let hero = home.hero[0]
        XCTAssertEqual(hero.kind, .movie)
        XCTAssertEqual(hero.year, 2019)
        XCTAssertEqual(hero.badges, ["1080p", "Audio EN RU", "Subtitles EN"])
        XCTAssertEqual(home.shelves.map(\.id), ["continue", "recently-played", "reading", "recent-movies", "recent-series", "watchlist"])
        XCTAssertNotNil(home.shelf(ShelfID.continueWatching))
    }

    func testMovieDetail() throws {
        let movie = try Samples.decode(ItemDetail.self, "item-movie.json")
        XCTAssertEqual(movie.id, 19)
        XCTAssertEqual(movie.title, "Big Buck Demo")
        XCTAssertTrue(movie.inWatchlist)
        XCTAssertTrue(movie.actions.play)
        let file = try XCTUnwrap(movie.primaryFile)
        XCTAssertEqual(file.id, 12)
        XCTAssertEqual(file.resolution, "1080p")
        XCTAssertEqual(file.audio.map(\.index), [1, 2])
        XCTAssertTrue(file.audio[0].isDefault)
        XCTAssertEqual(file.audio[1].language, "rus")
        XCTAssertEqual(file.subs.count, 2)
        XCTAssertEqual(file.subs[1].url, "/api/subs/12/1000.vtt?src=b70596c2")
        XCTAssertTrue(file.subs[1].external)
        XCTAssertTrue(file.subs[1].isText)
    }

    func testSeriesDetail() throws {
        let series = try Samples.decode(ItemDetail.self, "item-series.json")
        XCTAssertEqual(series.kind, .series)
        XCTAssertTrue(series.files.isEmpty)
        XCTAssertEqual(series.seasons.map(\.number), [1, 2])
        let episode = series.seasons[0].episodes[0]
        XCTAssertEqual(episode.seasonNo, 1)
        XCTAssertEqual(episode.episodeNo, 1)
        XCTAssertEqual(episode.seriesId, 2)
        XCTAssertEqual(episode.durationMs, 20023)
        XCTAssertEqual(series.next?.id, 4)

        let season = try Samples.decode(ItemDetail.self, "item-season.json")
        XCTAssertEqual(season.seasons.count, 1)

        let episodeDetail = try Samples.decode(ItemDetail.self, "item-episode.json")
        XCTAssertEqual(episodeDetail.primaryFile?.id, 2)
        XCTAssertNil(episodeDetail.primaryFile?.audio.first?.language)
    }

    func testPlayResponses() throws {
        let direct = try Samples.decode(PlayResponse.self, "play-direct.json")
        XCTAssertEqual(direct.mode, .direct)
        XCTAssertFalse(direct.mode.isHLS)
        XCTAssertNil(direct.hlsSessionID)
        XCTAssertTrue(direct.url.hasPrefix("/api/stream/"))

        let hls = try Samples.decode(PlayResponse.self, "play-mkv-hls.json")
        XCTAssertEqual(hls.mode, .remux)
        XCTAssertTrue(hls.hlsComplete)
        XCTAssertEqual(hls.hlsSessionID, "d4efc029ebb8590d")
        XCTAssertEqual(hls.quality.applied, "original")
        XCTAssertEqual(hls.subtitles.count, 2)

        let quality = try Samples.decode(PlayResponse.self, "play-transcode-quality.json")
        XCTAssertEqual(quality.mode, .transcode)
        XCTAssertEqual(quality.startSec, 10)
        XCTAssertEqual(quality.quality.applied, "480")

        let keepAlive = try Samples.decode(HLSStatus.self, "hls-keepalive.json")
        XCTAssertGreaterThan(keepAlive.segments, 0)
    }

    func testProgress() throws {
        let progress = try Samples.decode(PlaybackProgress.self, "progress-get.json")
        XCTAssertEqual(progress.positionMs, 15000)
        XCTAssertTrue(progress.exists)
        XCTAssertEqual(ResumePolicy.videoStartSec(progress), 15)

        let empty = try JSONDecoder().decode(PlaybackProgress.self, from: Data(#"{"positionMs":0,"durationMs":0,"finished":false,"locator":"","fraction":0,"updatedAt":null}"#.utf8))
        XCTAssertFalse(empty.exists)
        XCTAssertEqual(ResumePolicy.videoStartSec(empty), 0)
    }

    func testMusic() throws {
        let album = try Samples.decode(AlbumDetail.self, "music-album.json")
        XCTAssertEqual(album.card.kind, .album)
        XCTAssertEqual(album.artist?.name, "Sample Band")
        XCTAssertEqual(album.tracks.count, album.trackCount)
        XCTAssertEqual(album.quality, "Lossless · FLAC")

        let artist = try Samples.decode(ArtistDetail.self, "music-artist.json")
        XCTAssertEqual(artist.topTracks.count, 3)
        XCTAssertTrue(artist.appearsOn.isEmpty)

        let lyrics = try Samples.decode(Lyrics.self, "music-lyrics.json")
        XCTAssertTrue(lyrics.synced)
        XCTAssertEqual(lyrics.lines.map(\.t), [1, 5])
        XCTAssertNil(lyrics.lineIndex(at: 0.5))
        XCTAssertEqual(lyrics.lineIndex(at: 6), 1)

        let playlist = try Samples.decode(PlaylistDetail.self, "playlist.json")
        XCTAssertEqual(playlist.tracks.map(\.idx), [0, 1, 2])
        XCTAssertEqual(playlist.playlist.covers.count, 1)

        let home = try Samples.decode(ShelvesResponse.self, "music-home.json")
        XCTAssertEqual(home.shelf(ShelfID.playlists)?.cards.first?.kind, .playlist)

        let songs = try Samples.decode(Page<Track>.self, "music-songs.json")
        XCTAssertLessThan(songs.items.count, songs.total, "sample was captured with a small limit")
        XCTAssertTrue(songs.hasMore(after: 0))
        XCTAssertFalse(songs.hasMore(after: songs.total - songs.items.count))

        let genres = try Samples.decode(GenresResponse.self, "music-genres.json").genres
        XCTAssertEqual(genres.first?.name, "Rock")
    }

    func testBooks() throws {
        let audiobook = try Samples.decode(BookDetail.self, "book-audiobook.json")
        XCTAssertEqual(audiobook.kind, .audiobook)
        XCTAssertNil(audiobook.progress)
        XCTAssertNil(audiobook.series)
        XCTAssertEqual(audiobook.chapters.map(\.title), ["Opening", "Middle", "Ending"])
        XCTAssertEqual(audiobook.durationMs, 60000)

        let multi = try Samples.decode(BookDetail.self, "book-audiobook-multifile.json")
        XCTAssertEqual(multi.files.count, 2)

        let series = try Samples.decode(BookDetail.self, "book-comic.json")
        XCTAssertEqual(series.volumes.first?.fileId, 13)
        XCTAssertEqual(series.volumes.first?.pages, 3)
        XCTAssertEqual(series.volumes.first?.readingDirection, .rightToLeft)
        XCTAssertEqual(series.volumes.first?.seriesId, 20)

        let volume = try Samples.decode(BookDetail.self, "book-comic-volume.json")
        XCTAssertEqual(volume.readFileId, 13)
        XCTAssertEqual(volume.series?.name, "Hero Tales")
        XCTAssertEqual(volume.series?.index, 1)

        let pages = try Samples.decode(ComicPages.self, "comic-pages.json")
        XCTAssertEqual(pages.count, 3)
        XCTAssertEqual(pages.sizes.first, ComicPages.PageSize(width: 800, height: 1200))

        let home = try Samples.decode(ShelvesResponse.self, "books-home.json")
        XCTAssertEqual(home.shelves.first?.id, ShelfID.reading)
    }

    func testSearch() throws {
        let results = try Samples.decode(SearchResults.self, "search-music.json")
        XCTAssertEqual(results.songs.count, 3)
        XCTAssertFalse(results.isEmpty)
    }

    func testTolerantDecoding() throws {
        // Unknown kind, missing optional fields, a wrongly typed optional value and extra keys.
        let json = #"{"id": 7, "kind": "hologram", "title": "X", "year": "n/a", "future": {"a": 1}}"#
        let card = try JSONDecoder().decode(Card.self, from: Data(json.utf8))
        XCTAssertEqual(card.kind.rawValue, "hologram")
        XCTAssertNil(card.year)
        XCTAssertEqual(card.poster, "")
        XCTAssertEqual(card.badges, [])
        XCTAssertTrue(card.onServer)

        XCTAssertThrowsError(try JSONDecoder().decode(Card.self, from: Data(#"{"title": "no id"}"#.utf8)))

        let profile = try JSONDecoder().decode(Profile.self, from: Data(#"{"id": 3, "name": "N", "avatar": "sparkles"}"#.utf8))
        XCTAssertEqual(profile.avatarPreset, .grad8)
        XCTAssertFalse(profile.hasPassword)
    }

    func testCardRoundTrip() throws {
        let home = try Samples.decode(HomeResponse.self, "home.json")
        let cards = home.shelves.flatMap(\.cards)
        let data = try JSONEncoder().encode(cards)
        XCTAssertEqual(try JSONDecoder().decode([Card].self, from: data), cards)
    }
}
