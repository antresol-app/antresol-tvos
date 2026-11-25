import Foundation
import XCTest
@testable import AntresolKit

/// «Семья»: the other profiles' places in a title and «Продолжить с их места», as the web's
/// FamilyProgress has them (the same cases as its tests).
final class FamilyTests: XCTestCase {
    private let base = URL(string: "http://tv.test:8420")!

    private func client(_ transport: MockTransport) -> APIClient {
        APIClient(baseURL: base, token: "t", language: "ru", transport: transport)
    }

    private func member(_ id: Int = 2, _ name: String = "Alex", item: Int = 10, position: Int = 0, duration: Int = 0, fraction: Double = 0,
                        finished: Bool = false, season: Int? = nil, episode: Int? = nil, next: Bool = false, done: Int = 0, total: Int = 0) -> FamilyMember {
        FamilyMember(userId: id, name: name, itemId: item, positionMs: position, durationMs: duration, fraction: fraction, finished: finished,
                     season: season, episode: episode, next: next, done: done, total: total)
    }

    private let minute = 60_000

    // MARK: decoding

    static let answer = #"""
    {"members":[
      {"userId":2,"name":"Alex","avatar":"grad-3","photo":"/api/profiles/2/photo?v=1","isKid":false,"itemId":11,"positionMs":1020000,"durationMs":2700000,
       "fraction":0.38,"finished":false,"updatedAt":"2026-11-25T10:00:00.123456789Z","season":1,"episode":2,"title":"Pilot","done":1,"total":3},
      {"userId":3,"name":"Living Room","ownerName":"Max","avatar":"grad-9","itemId":11,"next":true,"updatedAt":"2026-11-25T09:00:00Z","season":1,"episode":2},
      {"name":"no id","itemId":5},
      {"userId":5,"name":"no item"},
      {"userId":4,"name":"Kim","itemId":12,"finished":true,"fraction":"wrong","positionMs":"x","updatedAt":"yesterday"}
    ]}
    """#

    func testMembersDecodeAndTheBrokenOnesAreDropped() async throws {
        let transport = MockTransport { _ in .json(Self.answer) }
        let list = try await client(transport).family(itemId: 7)
        XCTAssertEqual(list.map(\.name), ["Alex", "Living Room", "Kim"])
        let mama = list[0]
        XCTAssertEqual(mama.itemId, 11)
        XCTAssertEqual(mama.positionMs, 1_020_000)
        XCTAssertEqual(mama.season, 1)
        XCTAssertEqual(mama.title, "Pilot")
        XCTAssertEqual(mama.done, 1)
        XCTAssertEqual(mama.total, 3)
        XCTAssertEqual(mama.updatedAt, Timestamp.parse("2026-11-25T10:00:00.123456789Z"))
        XCTAssertEqual(mama.avatarPreset, .grad3)
        XCTAssertEqual(mama.photo, "/api/profiles/2/photo?v=1")
        XCTAssertEqual(mama.listName, "Alex")
        let device = list[1]
        XCTAssertEqual(device.listName, "Living Room · Max")
        XCTAssertEqual(device.avatarPreset, .fallback, "an avatar this app does not know is the grey one")
        XCTAssertTrue(device.next)
        // wrong types fall back, they do not fail the list
        let granny = list[2]
        XCTAssertTrue(granny.finished)
        XCTAssertEqual(granny.positionMs, 0)
        XCTAssertEqual(granny.fraction, 0)
        XCTAssertNil(granny.updatedAt)
        let seen = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(seen.httpMethod, "GET")
        XCTAssertEqual(seen.pathAndQuery, "/api/items/7/family")
    }

    func testNobodyIsAnEmptyListAndSoIsAServerWithoutIt() async throws {
        let none = try await client(MockTransport { _ in .json(#"{"members":[]}"#) }).family(itemId: 7)
        XCTAssertEqual(none, [])
        let missing = try await client(MockTransport { _ in .json("{}") }).family(itemId: 7)
        XCTAssertEqual(missing, [])
        for status in [400, 404, 405] {
            let older = try await client(MockTransport { _ in .json(#"{"error":"x"}"#, status: status) }).family(itemId: 7)
            XCTAssertEqual(older, [], "\(status)")
        }
        do {
            _ = try await client(MockTransport { _ in .json(#"{"error":"x"}"#, status: 500) }).family(itemId: 7)
            XCTFail("a server error is an error")
        } catch let error as APIError {
            XCTAssertEqual(error.statusCode, 500)
        }
    }

    func testAdoptPostsOnlyWhoseProgress() async throws {
        let transport = MockTransport { _ in .json(#"{"positionMs":2000000}"#) }
        try await client(transport).adoptProgress(itemId: 42, userId: 7)
        let seen = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(seen.httpMethod, "POST")
        XCTAssertEqual(seen.pathAndQuery, "/api/progress/42/adopt")
        let body = try JSONSerialization.jsonObject(with: try XCTUnwrap(seen.httpBody)) as? [String: Any]
        XCTAssertEqual(body as? [String: Int], ["userId": 7])
        XCTAssertEqual(transport.requests.count, 1, "only the profile's own progress is written: the server copies theirs")
    }

    func testAnAdoptTheServerRefusesIsAnError() async {
        let transport = MockTransport { _ in .json(#"{"error":"Не найдено"}"#, status: 404) }
        do {
            try await client(transport).adoptProgress(itemId: 42, userId: 7)
            XCTFail("a 404 is an error: nothing may start")
        } catch let error as APIError {
            XCTAssertEqual(error.statusCode, 404)
        } catch {
            XCTFail("\(error)")
        }
    }

    // MARK: places

    func testASeriesSaysWhereEachProfileIs() {
        let at = member(item: 11, position: 17 * minute, duration: 45 * minute, fraction: 0.38, season: 1, episode: 2, done: 1, total: 3)
        XCTAssertEqual(at.place(.series), .episode(FamilyCode(season: 1, episode: 2), minutes: 17))
        XCTAssertEqual(at.jump(.series), .watchEpisodeAt(FamilyCode(season: 1, episode: 2), clock: "17:00"))
        XCTAssertTrue(at.adopts)

        let next = member(3, "Sam", item: 11, season: 1, episode: 2, next: true, done: 1, total: 3)
        XCTAssertEqual(next.place(.series), .upNext(FamilyCode(season: 1, episode: 2)))
        XCTAssertEqual(next.jump(.series), .watchEpisode(FamilyCode(season: 1, episode: 2)))
        XCTAssertFalse(next.adopts, "a next episode just starts: nothing of theirs to take")

        let done = member(4, "Kim", finished: true, done: 3, total: 3)
        XCTAssertEqual(done.place(.series), .allWatched)
        XCTAssertEqual(done.jump(.series), .none)
        XCTAssertFalse(done.adopts)

        // an episode begun and left within the first half minute: the code alone
        let barely = member(item: 11, position: 10_000, season: 2, episode: 5)
        XCTAssertEqual(barely.place(.series), .episode(FamilyCode(season: 2, episode: 5), minutes: 0))
        // not started at all (no position): the episode from its start
        let fresh = member(item: 11, season: 2, episode: 5)
        XCTAssertEqual(fresh.jump(.series), .watchEpisode(FamilyCode(season: 2, episode: 5)))
        XCTAssertFalse(fresh.adopts)
    }

    func testAMovieOrEpisodeSaysTheTimeOfTheLength() {
        let at = member(position: 34 * minute, duration: 110 * minute)
        XCTAssertEqual(at.place(.movie), .time(positionMinutes: 34, clock: "34:00", durationMinutes: 110))
        XCTAssertEqual(at.place(.episode), at.place(.movie))
        XCTAssertEqual(member(position: 2_000_000, duration: 6_000_000).jump(.movie), .watchAt(clock: "33:20"))
        XCTAssertEqual(member(position: 3_723_000, duration: 6_000_000).jump(.episode), .watchAt(clock: "1:02:03"))
        // under half a minute: the clock stands in for the minutes
        XCTAssertEqual(member(position: 20_000, duration: 60_000).place(.movie), .time(positionMinutes: 0, clock: "0:20", durationMinutes: 1))
        // no known length
        XCTAssertEqual(member(position: 5 * minute).place(.movie), .time(positionMinutes: 5, clock: "5:00", durationMinutes: 0))
        // started with no position: nothing to continue
        XCTAssertEqual(member().jump(.movie), .none)
        XCTAssertFalse(member().adopts)

        let finished = member(finished: true)
        XCTAssertEqual(finished.place(.movie), .watched)
        XCTAssertEqual(finished.place(.episode), .watched)
        XCTAssertEqual(finished.jump(.movie), .none)
    }

    func testTheRingIsASeriesShareOrTheItemsOwn() {
        XCTAssertEqual(member(fraction: 0.3, done: 2, total: 4).ring, 0.5)
        XCTAssertEqual(member(fraction: 0.3).ring, 0.3)
        XCTAssertEqual(member(fraction: 7).ring, 1)
        XCTAssertEqual(member(fraction: -1).ring, 0)
        XCTAssertEqual(member(fraction: 0.3, finished: true, done: 1, total: 4).ring, 1)
        XCTAssertEqual(member(done: 9, total: 4).ring, 1)
    }

    func testAdoptingNeedsAPositionOrAReaderPlace() {
        XCTAssertTrue(member(position: 1).adopts)
        XCTAssertFalse(member(position: 1, next: true).adopts)
        XCTAssertFalse(member(position: 1, finished: true).adopts)
        var reader = member()
        reader.locator = "page:3"
        XCTAssertTrue(reader.adopts)
    }

    func testAPlaceToLookAtIsStartedUnfinishedAndInThisItem() {
        XCTAssertTrue(member(item: 10, position: 1).hasPlace(in: 10))
        XCTAssertTrue(member(item: 10, fraction: 0.1).hasPlace(in: 10))
        XCTAssertFalse(member(item: 11, position: 1).hasPlace(in: 10), "another episode")
        XCTAssertFalse(member(item: 10, position: 1, finished: true).hasPlace(in: 10))
        XCTAssertFalse(member(item: 10).hasPlace(in: 10))
    }

    func testTheKindOfAPage() {
        XCTAssertEqual(FamilyKind(.movie), .movie)
        XCTAssertEqual(FamilyKind(.episode), .episode)
        XCTAssertEqual(FamilyKind(.series), .series)
        XCTAssertEqual(FamilyKind(.season), .series, "a season's page is its series'")
        XCTAssertNil(FamilyKind(.album))
        XCTAssertNil(FamilyKind(.book))
    }

    func testTheSpecialsCodeIsSeasonZero() {
        XCTAssertTrue(member(season: 0, episode: 3).code.isSpecial)
        XCTAssertFalse(member(season: 1, episode: 3).code.isSpecial)
    }

    // MARK: the folded line

    func testNothingIsShownWhenNobodyHasProgress() {
        XCTAssertNil(FamilyLine([], kind: .movie))
    }

    func testTheLineIsTheNewestAndHowManyMore() throws {
        let members = [
            member(2, "Alex", item: 11, position: 17 * minute, season: 1, episode: 2),
            member(3, "Sam", item: 11, season: 1, episode: 2, next: true),
            member(4, "Kim", finished: true),
        ]
        let line = try XCTUnwrap(FamilyLine(members, kind: .series))
        XCTAssertEqual(line.first.name, "Alex")
        XCTAssertEqual(line.place, .episode(FamilyCode(season: 1, episode: 2), minutes: 17))
        XCTAssertEqual(line.more, 2)
        XCTAssertEqual(line.shown.count, 3)
        XCTAssertEqual(line.hiddenFaces, 0)
        XCTAssertTrue(line.hasJump)
        let one = try XCTUnwrap(FamilyLine([members[0]], kind: .series))
        XCTAssertEqual(one.more, 0)
    }

    func testTheLineShowsFourFacesThenTheRest() throws {
        let six = (1...6).map { member($0, "P\($0)", position: 1) }
        let line = try XCTUnwrap(FamilyLine(six, kind: .movie))
        XCTAssertEqual(line.shown.map(\.userId), [1, 2, 3, 4])
        XCTAssertEqual(line.hiddenFaces, 2)
        XCTAssertEqual(line.more, 5)
    }

    func testWhenEveryoneIsDoneThereIsNothingToContinue() throws {
        let line = try XCTUnwrap(FamilyLine([member(finished: true), member(3, "Max", finished: true)], kind: .movie))
        XCTAssertFalse(line.hasJump)
    }

    // MARK: when

    func testWhenIsSecondsMinutesHoursYesterdayThenTheDate() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func ago(_ seconds: Double) -> FamilyWhen? { FamilyWhen.since(now.addingTimeInterval(-seconds), now: now) }
        XCTAssertEqual(ago(5), .now)
        XCTAssertEqual(ago(59), .now)
        XCTAssertEqual(ago(60), .minutes(1))
        XCTAssertEqual(ago(59 * 60 + 59), .minutes(59))
        XCTAssertEqual(ago(2 * 3600 + 10), .hours(2))
        XCTAssertEqual(ago(23 * 3600), .hours(23))
        XCTAssertEqual(ago(30 * 3600), .yesterday)
        XCTAssertEqual(ago(3 * 86400), .date(now.addingTimeInterval(-3 * 86400)))
        XCTAssertEqual(FamilyWhen.since(now.addingTimeInterval(500), now: now), .now, "a clock a little ahead is just now")
        XCTAssertNil(FamilyWhen.since(nil, now: now))
    }

    // MARK: the player's hold

    func testAPeekedPlaceIsNotSavedUntilItPlaysOn() {
        let hold = FamilyHold(position: 600, target: 2000)
        // at the target, and for five seconds after: the place from before the jump is saved
        XCTAssertEqual(FamilyHold.held(hold, now: 2000).position, 600)
        XCTAssertEqual(FamilyHold.held(hold, now: 1999.5).position, 600)
        XCTAssertEqual(FamilyHold.held(hold, now: 2004.9).position, 600)
        XCTAssertFalse(FamilyHold.held(hold, now: 2004.9).release)
        // it played on there: the real position, and the hold is over
        let played = FamilyHold.held(hold, now: 2005)
        XCTAssertEqual(played.position, 2005)
        XCTAssertTrue(played.release)
        // the viewer went somewhere else first
        let elsewhere = FamilyHold.held(hold, now: 900)
        XCTAssertEqual(elsewhere.position, 900)
        XCTAssertTrue(elsewhere.release)
        // no hold: as it is
        XCTAssertEqual(FamilyHold.held(nil, now: 42).position, 42)
        XCTAssertFalse(FamilyHold.held(nil, now: 42).release)
    }

    func testTheClock() {
        XCTAssertEqual(FamilyMember.clock(seconds: 0), "0:00")
        XCTAssertEqual(FamilyMember.clock(seconds: 59.9), "0:59")
        XCTAssertEqual(FamilyMember.clock(seconds: 2040), "34:00")
        XCTAssertEqual(FamilyMember.clock(seconds: 3723), "1:02:03")
        XCTAssertEqual(FamilyMember.clock(seconds: -4), "0:00")
        XCTAssertEqual(FamilyMember.clock(seconds: .nan), "0:00")
    }
}
