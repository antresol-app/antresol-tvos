import Foundation
import XCTest
@testable import AntresolKit
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class EpisodeGuideTests: XCTestCase {
    let base = URL(string: "http://tv.test:8420")!

    func testDecodesTheAnswer() throws {
        let answer = try Samples.decode(TrackingEpisodes.self, "tracking-episodes.json")
        XCTAssertEqual(answer.title.kind, "series")
        XCTAssertEqual(answer.title.tmdbId, 1399)
        XCTAssertEqual(answer.title.itemId, 2)
        XCTAssertEqual(answer.episodes.count, 6)

        let second = answer.episodes[1]
        XCTAssertEqual(second.season, 1)
        XCTAssertEqual(second.number, 2)
        XCTAssertEqual(second.airDate, "2026-09-08")
        XCTAssertEqual(second.positionSec, 610)
        XCTAssertEqual(second.sources.map(\.kind), ["library", "x-source"])
        XCTAssertEqual(second.sources[0].meta, TrackingSourceMeta(itemId: 5, fileId: 50))
        XCTAssertEqual(second.sources[1].quality, "2160p")
        XCTAssertEqual(second.libraryItemId, 5)

        XCTAssertTrue(answer.episodes[0].watched)
        XCTAssertTrue(answer.episodes[2].new)
        XCTAssertNil(answer.episodes[2].libraryItemId, "an online source is not a library file")
        XCTAssertNil(answer.episodes[0].positionSec)
    }

    func testToleratesMissingFields() throws {
        let json = #"{"episodes":[{"season":1,"number":1,"sources":[{"kind":"library","meta":{"itemId":9}}]},{"number":2}]}"#
        let answer = try JSONDecoder().decode(TrackingEpisodes.self, from: Data(json.utf8))
        XCTAssertEqual(answer.title, TrackingTitle())
        XCTAssertEqual(answer.episodes.map(\.number), [1, 2])
        XCTAssertEqual(answer.episodes[0].libraryItemId, 9)
        XCTAssertEqual(answer.episodes[1].airDate, "")
        XCTAssertEqual(answer.episodes[1].sources, [])
    }

    func testStates() throws {
        let library = try Samples.decode(ItemDetail.self, "item-series.json").seasons
        let answer = try Samples.decode(TrackingEpisodes.self, "tracking-episodes.json")
        let guide = EpisodeGuide(library: library, tracking: answer, today: "2026-11-14")

        XCTAssertTrue(guide.isFull)
        XCTAssertEqual(guide.seasons.map(\.number), [1, 2])
        XCTAssertEqual(guide.seasons.map(\.libraryId), [3, 11])

        let first = guide.seasons[0].episodes
        XCTAssertEqual(first.map(\.number), [1, 2, 3, 4, 5])
        XCTAssertEqual(first.map(\.state), [.downloaded, .downloaded, .missing, .upcoming, .upcoming])
        XCTAssertEqual(first[0].card?.id, 4, "a downloaded episode keeps its library card")
        XCTAssertEqual(first[1].card?.id, 5)
        XCTAssertNil(first[2].card)
        XCTAssertEqual(first[2].name, "Third")
        XCTAssertEqual(first[3].airDate, "2026-12-01")
        XCTAssertEqual(guide.seasons[1].episodes.map(\.card?.id), [12])
    }

    func testAnEpisodeAiringTodayHasAired() throws {
        let answer = TrackingEpisodes(title: TrackingTitle(), episodes: [
            TrackingEpisode(season: 1, number: 1, airDate: "2026-11-14"),
            TrackingEpisode(season: 1, number: 2, airDate: "2026-11-15"),
        ])
        let guide = EpisodeGuide(library: [], tracking: answer, today: "2026-11-14")
        XCTAssertEqual(guide.seasons[0].episodes.map(\.state), [.missing, .upcoming])
    }

    /// «New» is the server's flag on an aired episode the profile has not watched, as on the web.
    func testNewIsAnAiredEpisodeNotWatchedYet() throws {
        let answer = TrackingEpisodes(title: TrackingTitle(), episodes: [
            TrackingEpisode(season: 1, number: 1, airDate: "2026-11-10", new: true),
            TrackingEpisode(season: 1, number: 2, airDate: "2026-11-10", watched: true, new: true),
            TrackingEpisode(season: 1, number: 3, airDate: "2026-12-01", new: true),
            TrackingEpisode(season: 1, number: 4, airDate: "2026-11-10"),
        ])
        let guide = EpisodeGuide(library: [], tracking: answer, today: "2026-11-14")
        XCTAssertEqual(guide.seasons[0].episodes.map(\.isNew), [true, false, false, false])
        let library = try Samples.decode(ItemDetail.self, "item-series.json").seasons
        XCTAssertTrue(EpisodeGuide(library: library, tracking: nil, today: "2026-11-14").seasons.flatMap(\.episodes).allSatisfy { !$0.isNew })
    }

    func testWatchedMarks() throws {
        let library = try Samples.decode(ItemDetail.self, "item-series.json").seasons
        let answer = TrackingEpisodes(title: TrackingTitle(), episodes: [
            TrackingEpisode(season: 1, number: 1, watched: true, sources: [TrackingSource(kind: "library", meta: TrackingSourceMeta(itemId: 4))]),
            TrackingEpisode(season: 1, number: 3, airDate: "2026-01-01", watched: true),
        ])
        let guide = EpisodeGuide(library: library, tracking: answer, today: "2026-11-14")
        let episodes = guide.seasons[0].episodes
        let card = try XCTUnwrap(library[0].episodes.first { $0.id == 4 })
        XCTAssertEqual(episodes[0].watched, card.watched, "a library episode shows the library's mark, as before")
        XCTAssertTrue(try XCTUnwrap(episodes.first { $0.number == 3 }).watched)
    }

    func testLibraryEpisodesTheAnswerLacksAreKept() throws {
        let library = try Samples.decode(ItemDetail.self, "item-series.json").seasons
        // Only S1E2 is named, without a library source; the library's S1E1, S1E2 and S2E1
        // must still show and play.
        let answer = TrackingEpisodes(title: TrackingTitle(), episodes: [
            TrackingEpisode(season: 1, number: 2, name: "Second", airDate: "2026-09-08"),
            TrackingEpisode(season: 1, number: 3, airDate: "2026-09-15"),
        ])
        let guide = EpisodeGuide(library: library, tracking: answer, today: "2026-11-14")
        XCTAssertEqual(guide.seasons.map(\.number), [1, 2])
        let first = guide.seasons[0].episodes
        XCTAssertEqual(first.map(\.number), [1, 2, 3])
        XCTAssertEqual(first.map(\.card?.id), [4, 5, nil])
        XCTAssertEqual(first[1].airDate, "2026-09-08", "the slot keeps its air date")
        XCTAssertEqual(first.map(\.state), [.downloaded, .downloaded, .missing])
        XCTAssertEqual(guide.seasons[1].episodes.map(\.card?.id), [12])
    }

    func testALibrarySourceWithoutACardStillPlays() throws {
        let answer = TrackingEpisodes(title: TrackingTitle(), episodes: [
            TrackingEpisode(season: 0, number: 1, name: "Special", sources: [TrackingSource(kind: "library", meta: TrackingSourceMeta(itemId: 77))]),
        ])
        let guide = EpisodeGuide(library: [], tracking: answer, today: "2026-11-14")
        let episode = try XCTUnwrap(guide.seasons.first?.episodes.first)
        XCTAssertEqual(episode.state, .downloaded, "no air date, but a file: downloaded, not upcoming")
        XCTAssertEqual(episode.card?.id, 77)
        XCTAssertEqual(episode.card?.kind, .episode)
        XCTAssertEqual(episode.name, "Special")
        XCTAssertNil(guide.seasons[0].libraryId)
    }

    func testFallsBackToTheLibrary() throws {
        let library = try Samples.decode(ItemDetail.self, "item-series.json").seasons
        for tracking in [nil, TrackingEpisodes(title: TrackingTitle(), episodes: [])] {
            let guide = EpisodeGuide(library: library, tracking: tracking, today: "2026-11-14")
            XCTAssertFalse(guide.isFull)
            XCTAssertEqual(guide.seasons.map(\.libraryId), [3, 11])
            XCTAssertEqual(guide.seasons.flatMap(\.episodes).map(\.card?.id), [4, 5, 12])
            XCTAssertTrue(guide.seasons.flatMap(\.episodes).allSatisfy(\.isDownloaded))
        }
    }

    func testInitialSeason() throws {
        let library = try Samples.decode(ItemDetail.self, "item-series.json").seasons
        let answer = TrackingEpisodes(title: TrackingTitle(), episodes: [
            TrackingEpisode(season: 0, number: 1, airDate: "2020-01-01"),
            TrackingEpisode(season: 1, number: 1, sources: [TrackingSource(kind: "library", meta: TrackingSourceMeta(itemId: 4))]),
            TrackingEpisode(season: 2, number: 1, sources: [TrackingSource(kind: "library", meta: TrackingSourceMeta(itemId: 12))]),
        ])
        let guide = EpisodeGuide(library: library, tracking: answer, today: "2026-11-14")
        XCTAssertEqual(guide.initialSeason(preferredItemId: 12), 2, "the next episode's season")
        XCTAssertEqual(guide.initialSeason(preferredItemId: 11), 2, "a season card's season")
        XCTAssertEqual(guide.initialSeason(preferredItemId: nil), 1, "the first season with a download, not the specials")
        XCTAssertNil(EpisodeGuide(library: [], tracking: nil, today: "").initialSeason(preferredItemId: nil))
    }

    func testDayAndAirDay() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Moscow")!
        let date = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 3, day: 7, hour: 23, minute: 30)))
        XCTAssertEqual(EpisodeGuide.day(date, calendar: calendar), "2026-03-07")

        let episode = GuideEpisode(tracking: TrackingEpisode(season: 1, number: 1, airDate: "2026-12-01"), card: nil, today: "2026-11-14")
        XCTAssertEqual(episode.airDay(calendar: calendar).map { EpisodeGuide.day($0, calendar: calendar) }, "2026-12-01")
        XCTAssertNil(GuideEpisode(tracking: TrackingEpisode(season: 1, number: 1), card: nil, today: "x").airDay())
    }

    func testAMissingEpisodeAWayPlaysIsNotDimmed() {
        // A library episode is never dimmed; a way changes nothing for it.
        for focused in [false, true] {
            XCTAssertEqual(GuideEpisode.State.downloaded.opacity(isFocused: focused, playable: false), 1)
            XCTAssertEqual(GuideEpisode.State.downloaded.opacity(isFocused: focused, playable: true), 1)
        }
        // Missing and nothing plays it: dimmed, focus lifts the dimming.
        XCTAssertEqual(GuideEpisode.State.missing.opacity(isFocused: false, playable: false), 0.55)
        XCTAssertEqual(GuideEpisode.State.missing.opacity(isFocused: true, playable: false), 0.8)
        // Missing but a way plays it: as bright as a library episode, focused or not.
        XCTAssertEqual(GuideEpisode.State.missing.opacity(isFocused: false, playable: true), 1)
        XCTAssertEqual(GuideEpisode.State.missing.opacity(isFocused: true, playable: true), 1)
        // Still to air: greyed with or without a way (the page offers none for it anyway).
        for playable in [false, true] {
            XCTAssertEqual(GuideEpisode.State.upcoming.opacity(isFocused: false, playable: playable), 0.35)
            XCTAssertEqual(GuideEpisode.State.upcoming.opacity(isFocused: true, playable: playable), 0.6)
        }
    }

    func testClientRequestAndFallbackStatuses() async throws {
        let sample = try Samples.data("tracking-episodes.json")
        let transport = MockTransport { request in
            request.url?.path.contains("/9/") == true
                ? .json(#"{"error":"Не найдено"}"#, status: 404)
                : MockTransport.Reply(status: 200, body: sample, headers: [:])
        }
        let client = APIClient(baseURL: base, token: "t", language: "en", transport: transport)
        let answer = try await client.trackingEpisodes(kind: .series, tmdbId: 1399)
        XCTAssertEqual(answer.episodes.count, 6)
        XCTAssertEqual(transport.requests.last?.httpMethod, "GET")
        XCTAssertEqual(transport.requests.last?.pathAndQuery, "/api/tracking/series/1399/episodes")

        do {
            _ = try await client.trackingEpisodes(kind: .series, tmdbId: 9)
            XCTFail("expected 404")
        } catch let error as APIError {
            XCTAssertTrue(error.isNotFound)
        }
    }
}
