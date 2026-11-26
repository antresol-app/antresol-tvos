import Foundation
import XCTest
@testable import AntresolKit

/// Who the resume prompt offers beside this profile's own place, and when it is shown.
final class FamilyResumeTests: XCTestCase {
    private let minute = 60_000
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func member(
        _ id: Int, item: Int = 10, position: Int, finished: Bool = false, next: Bool = false, ago: TimeInterval? = 3600,
        season: Int? = nil, episode: Int? = nil
    ) -> FamilyMember {
        FamilyMember(
            userId: id, name: "P\(id)", itemId: item, positionMs: position, durationMs: 110 * minute, finished: finished,
            updatedAt: ago.map { now.addingTimeInterval(-$0) }, season: season, episode: episode, next: next
        )
    }

    // MARK: who qualifies

    func testAPlaceFurtherThanTwoMinutesFromOursQualifies() {
        XCTAssertTrue(FamilyResume.qualifies(member(1, position: 72 * minute), playing: 10, ownMs: 34 * minute))
        XCTAssertTrue(FamilyResume.qualifies(member(1, position: 34 * minute), playing: 10, ownMs: 40 * minute), "earlier than ours counts too")
    }

    func testAPlaceWithinTwoMinutesOfOursDoesNot() {
        XCTAssertFalse(FamilyResume.qualifies(member(1, position: 35 * minute), playing: 10, ownMs: 34 * minute))
        XCTAssertFalse(FamilyResume.qualifies(member(1, position: 34 * minute), playing: 10, ownMs: 34 * minute))
        XCTAssertFalse(FamilyResume.qualifies(member(1, position: 36 * minute), playing: 10, ownMs: 34 * minute), "exactly two minutes is not more")
        XCTAssertTrue(FamilyResume.qualifies(member(1, position: 36 * minute + 1), playing: 10, ownMs: 34 * minute))
    }

    func testWithoutOurOwnPlaceTheStartIsTheOneToBeFurtherFrom() {
        XCTAssertTrue(FamilyResume.qualifies(member(1, position: 34 * minute), playing: 10, ownMs: 0))
        XCTAssertFalse(FamilyResume.qualifies(member(1, position: 90_000), playing: 10, ownMs: 0), "a minute and a half in is hardly a place")
        XCTAssertTrue(FamilyResume.qualifies(member(1, position: 130_000), playing: 10, ownMs: 0))
    }

    func testFinishedNextAndNotStartedDoNot() {
        XCTAssertFalse(FamilyResume.qualifies(member(1, position: 110 * minute, finished: true), playing: 10, ownMs: 0))
        XCTAssertFalse(FamilyResume.qualifies(member(1, item: 11, position: 0, next: true), playing: 10, ownMs: 0), "a next episode nobody started")
        XCTAssertFalse(FamilyResume.qualifies(member(1, item: 11, position: 40 * minute, next: true), playing: 10, ownMs: 0), "next says it is not started")
        XCTAssertFalse(FamilyResume.qualifies(member(1, position: 0), playing: 10, ownMs: 0))
        XCTAssertFalse(FamilyResume.qualifies(member(1, item: 11, position: 0), playing: 10, ownMs: 0), "another episode, but no place in it")
    }

    func testAnotherEpisodeAlwaysQualifies() {
        // even a place equal to ours: it is in the other episode
        XCTAssertTrue(FamilyResume.qualifies(member(1, item: 11, position: 34 * minute, season: 1, episode: 5), playing: 10, ownMs: 34 * minute))
        XCTAssertTrue(FamilyResume.qualifies(member(1, item: 11, position: 20_000, season: 1, episode: 5), playing: 10, ownMs: 0))
    }

    func testAFinishedProfileOfAnotherEpisodeStillDoesNot() {
        XCTAssertFalse(FamilyResume.qualifies(member(1, item: 11, position: 45 * minute, finished: true), playing: 10, ownMs: 0))
    }

    // MARK: order and count

    func testNewestFirstAtMostThree() {
        let members = [
            member(1, position: 30 * minute, ago: 7200),
            member(2, position: 50 * minute, ago: 60),
            member(3, position: 70 * minute, ago: 86_400),
            member(4, position: 90 * minute, ago: 600),
            member(5, position: 10 * minute, ago: 5 * 86_400),
        ]
        XCTAssertEqual(FamilyResume.offers(members, playing: 10, ownMs: 0).map(\.userId), [2, 4, 1])
    }

    func testOnlyTheOnesThatQualifyAreCountedAgainstTheLimit() {
        let members = [
            member(1, position: 110 * minute, finished: true, ago: 10),
            member(2, position: 34 * minute + 1000, ago: 20),
            member(3, position: 50 * minute, ago: 30),
            member(4, position: 60 * minute, ago: 40),
            member(5, position: 80 * minute, ago: 50),
            member(6, position: 90 * minute, ago: 60),
        ]
        XCTAssertEqual(FamilyResume.offers(members, playing: 10, ownMs: 34 * minute).map(\.userId), [3, 4, 5])
    }

    func testAnUnknownTimeGoesLastAndEqualTimesKeepTheServersOrder() {
        let members = [
            member(1, position: 30 * minute, ago: nil),
            member(2, position: 40 * minute, ago: 100),
            member(3, position: 50 * minute, ago: 100),
        ]
        XCTAssertEqual(FamilyResume.offers(members, playing: 10, ownMs: 0).map(\.userId), [2, 3, 1])
    }

    func testNobodyOffersNothing() {
        XCTAssertEqual(FamilyResume.offers([], playing: 10, ownMs: 0), [])
        XCTAssertEqual(FamilyResume.offers([member(1, position: 34 * minute)], playing: 10, ownMs: 34 * minute), [])
    }

    func testAMixOfEpisodesOfASeries() {
        // playing episode 10 (S1 E3), at 5 minutes in it
        let members = [
            member(1, item: 10, position: 6 * minute, ago: 10, season: 1, episode: 3),
            member(2, item: 12, position: 12 * minute + 40_000, ago: 20, season: 1, episode: 5),
            member(3, item: 11, position: 0, next: true, ago: 30, season: 1, episode: 4),
            member(4, item: 10, position: 40 * minute, ago: 40, season: 1, episode: 3),
        ]
        XCTAssertEqual(FamilyResume.offers(members, playing: 10, ownMs: 5 * minute).map(\.userId), [2, 4])
    }

    // MARK: the prompt

    func testThePromptIsAsBeforeWhenNobodyIsOffered() {
        XCTAssertTrue(FamilyResume.showsPrompt(asksForOwn: true, ownSec: 2050, offers: []))
        XCTAssertFalse(FamilyResume.showsPrompt(asksForOwn: true, ownSec: 3, offers: []), "under five seconds is no place")
        XCTAssertFalse(FamilyResume.showsPrompt(asksForOwn: false, ownSec: 2050, offers: []), "a start that does not ask goes straight on")
        XCTAssertFalse(FamilyResume.showsPrompt(asksForOwn: true, ownSec: 0, offers: []))
    }

    func testAnOfferShowsThePromptForAnyStartWithOrWithoutAPlaceOfOurOwn() {
        let offered = [member(1, position: 72 * minute)]
        XCTAssertTrue(FamilyResume.showsPrompt(asksForOwn: false, ownSec: 0, offers: offered))
        XCTAssertTrue(FamilyResume.showsPrompt(asksForOwn: false, ownSec: 2050, offers: offered))
        XCTAssertTrue(FamilyResume.showsPrompt(asksForOwn: true, ownSec: 0, offers: offered))
    }

    func testOurOwnPlaceNeedsFiveSeconds() {
        XCTAssertFalse(FamilyResume.hasOwnPlace(0))
        XCTAssertFalse(FamilyResume.hasOwnPlace(4.9))
        XCTAssertTrue(FamilyResume.hasOwnPlace(5))
    }

    // MARK: what is asked

    func testAnEpisodeAsksAboutItsSeriesAndAFilmAboutItself() {
        XCTAssertEqual(FamilyResume.askedItem(itemId: 5, kind: .episode, seriesId: 2), 2)
        XCTAssertEqual(FamilyResume.askedItem(itemId: 5, kind: .episode, seriesId: nil), 5)
        XCTAssertEqual(FamilyResume.askedItem(itemId: 19, kind: .movie, seriesId: nil), 19)
    }
}
