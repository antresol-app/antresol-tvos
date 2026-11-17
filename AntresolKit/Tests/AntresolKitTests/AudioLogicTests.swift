import Foundation
import XCTest
@testable import AntresolKit

/// A deterministic generator so shuffled orders are reproducible.
private struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64

    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state
    }
}

final class PlayQueueTests: XCTestCase {
    func testOrderAndRepeat() {
        var queue = PlayQueue([1, 2, 3], startAt: 1)
        XCTAssertEqual(queue.current?.element, 2)
        XCTAssertEqual(queue.upcoming.map(\.element), [3])
        XCTAssertEqual(queue.nextIndex, 2)
        XCTAssertEqual(queue.previousIndex, 0)

        queue.move(to: 2)
        XCTAssertNil(queue.indexAfterCurrentEnds)
        queue.repeatMode = .all
        XCTAssertEqual(queue.indexAfterCurrentEnds, 0)
        queue.repeatMode = .one
        XCTAssertEqual(queue.indexAfterCurrentEnds, 2)
        XCTAssertNil(queue.nextIndex, "next skips ahead even with repeat one; nothing after the last item")

        queue.move(to: 0)
        queue.repeatMode = .off
        XCTAssertNil(queue.previousIndex)
        queue.repeatMode = .all
        XCTAssertEqual(queue.previousIndex, 2)
        XCTAssertEqual(RepeatMode.off.next, .all)
        XCTAssertEqual(RepeatMode.one.next, .off)
    }

    func testExtendAppendsInOrderWhenNotShuffled() {
        var queue = PlayQueue([1, 2, 3], startAt: 1)
        queue.extend(with: [4, 5])
        XCTAssertEqual(queue.items.map(\.element), [1, 2, 3, 4, 5])
        XCTAssertEqual(queue.current?.element, 2)

        var empty = PlayQueue<Int>()
        empty.extend(with: [7])
        XCTAssertEqual(empty.current?.element, 7)
    }

    func testExtendMixesIntoUpcomingWhenShuffled() {
        var generator = SeededGenerator(state: 7)
        var queue = PlayQueue(Array(1...5), startAt: 2)
        queue.setShuffle(true, using: &generator)
        queue.move(to: 2)
        let played = queue.items.prefix(3).map(\.element)
        queue.extend(with: Array(6...25), using: &generator)
        XCTAssertEqual(queue.items.prefix(3).map(\.element), played, "what has played and the current item stay put")
        XCTAssertEqual(queue.currentIndex, 2)
        XCTAssertEqual(Set(queue.items.map(\.element)), Set(1...25))
        XCTAssertNotEqual(Array(queue.items.suffix(20).map(\.element)), Array(6...25), "new items are mixed in")

        queue.setShuffle(false)
        XCTAssertEqual(queue.items.map(\.element), Array(1...25), "the original order has them at the end")
        XCTAssertEqual(queue.current?.element, played[2])
    }

    func testShuffleKeepsCurrentAndRestores() {
        var generator = SeededGenerator(state: 42)
        var queue = PlayQueue(Array(1...20), startAt: 5)
        let current = queue.current
        queue.setShuffle(true, using: &generator)
        XCTAssertTrue(queue.isShuffled)
        XCTAssertEqual(queue.currentIndex, 0)
        XCTAssertEqual(queue.current, current)
        XCTAssertEqual(Set(queue.items.map(\.element)), Set(1...20))
        XCTAssertNotEqual(queue.items.map(\.element), [6] + (1...20).filter { $0 != 6 }, "the rest is shuffled")

        queue.move(to: 3)
        let playing = queue.current
        queue.setShuffle(false)
        XCTAssertEqual(queue.items.map(\.element), Array(1...20))
        XCTAssertEqual(queue.current, playing)
    }

    func testInsertAppendRemove() {
        var queue = PlayQueue(["a", "b", "c"])
        queue.insertNext(["x"])
        XCTAssertEqual(queue.items.map(\.element), ["a", "x", "b", "c"])
        queue.append(contentsOf: ["z"])
        XCTAssertEqual(queue.items.map(\.element), ["a", "x", "b", "c", "z"])
        queue.move(to: 2)
        queue.remove(entry: queue.items[1].id)
        XCTAssertEqual(queue.items.map(\.element), ["a", "b", "c", "z"])
        XCTAssertEqual(queue.current?.element, "b")
        queue.remove(entry: queue.current!.id)
        XCTAssertEqual(queue.count, 4, "the current entry stays")
        queue.setShuffle(true)
        queue.setShuffle(false)
        XCTAssertEqual(queue.items.map(\.element), ["a", "b", "c", "z"], "inserted items keep their place in the original order")

        var empty = PlayQueue<Int>()
        XCTAssertNil(empty.current)
        empty.insertNext([7])
        XCTAssertEqual(empty.current?.element, 7)
    }

    func testDuplicatesAreDistinctEntries() {
        var queue = PlayQueue([5, 5])
        XCTAssertNotEqual(queue.items[0].id, queue.items[1].id)
        XCTAssertEqual(queue.move(toEntry: queue.items[1].id)?.element, 5)
        XCTAssertEqual(queue.currentIndex, 1)
    }
}

final class ScrobbleTrackerTests: XCTestCase {
    func testRecordsOnceAfterThreshold() {
        var tracker = ScrobbleTracker(trackId: 1, durationMs: 20_000)
        XCTAssertEqual(tracker.thresholdSeconds, 10)
        var fired = 0
        var position = 0.0
        while position < 20 {
            if tracker.advance(to: position) { fired += 1 }
            position += 0.5
        }
        XCTAssertEqual(fired, 1)
        XCTAssertTrue(tracker.isRecorded)
    }

    func testSeeksDoNotCount() {
        var tracker = ScrobbleTracker(trackId: 1, durationMs: 600_000)
        XCTAssertFalse(tracker.advance(to: 0))
        XCTAssertFalse(tracker.advance(to: 200), "a jump is a seek")
        XCTAssertFalse(tracker.advance(to: 100))
        XCTAssertEqual(tracker.playedSeconds, 0)
        tracker.resetPosition()
        XCTAssertFalse(tracker.advance(to: 300))
        XCTAssertFalse(tracker.advance(to: 301))
        XCTAssertEqual(tracker.playedSeconds, 1)
    }
}

/// A seek inside a song: natively in an original file, by asking for the stream again
/// in a transcoded one, and held while the item of a song not known yet is not ready.
final class SongSeekTests: XCTestCase {
    func testASeekBeforeAnUnknownSongIsReadyIsHeldAndDecidedThen() {
        // The song started without waiting for the probe; the seek comes before the item is ready.
        XCTAssertEqual(SongSeek.plan(knownTranscoded: false, isReady: false, hasSeekableRanges: false), .hold)
        // Ready, and it has no ranges after all: the held seek reloads the stream
        // (a native seek would do nothing and the bar would fall back to 0).
        XCTAssertEqual(SongSeek.plan(knownTranscoded: false, isReady: true, hasSeekableRanges: false), .reload)
        // The probe answered meanwhile.
        XCTAssertEqual(SongSeek.plan(knownTranscoded: true, isReady: true, hasSeekableRanges: false), .reload)
        // Ready with ranges: an original file.
        XCTAssertEqual(SongSeek.plan(knownTranscoded: false, isReady: true, hasSeekableRanges: true), .native)
    }

    func testAKnownTranscodedSongReloadsWhateverTheItemsState() {
        XCTAssertEqual(SongSeek.plan(knownTranscoded: true, isReady: false, hasSeekableRanges: false), .reload)
        XCTAssertEqual(SongSeek.plan(knownTranscoded: true, isReady: true, hasSeekableRanges: true), .reload)
    }

    /// A held seek, decided when the item is ready. Nothing to seek in does not by
    /// itself make a song transcoded for the session: an original file's ranges can come
    /// after it is ready.
    func testAHeldSeekTakesASongAsTranscodedOnlyOnTheServersWordOrASecondTime() {
        // Ranges there: the player seeks.
        XCTAssertEqual(HeldSongSeek.plan(knownTranscoded: false, serverAnswer: nil, hasSeekableRanges: true, reloadedBefore: false), .native)
        XCTAssertEqual(HeldSongSeek.plan(knownTranscoded: false, serverAnswer: false, hasSeekableRanges: true, reloadedBefore: false), .native)
        // No ranges, and the server has not answered: the stream is asked for again
        // (that load asks the server first), and nothing is remembered.
        XCTAssertEqual(HeldSongSeek.plan(knownTranscoded: false, serverAnswer: nil, hasSeekableRanges: false, reloadedBefore: false), .reload(remember: false))
        // The server said "the original file": the ranges are late, the player seeks.
        XCTAssertEqual(HeldSongSeek.plan(knownTranscoded: false, serverAnswer: false, hasSeekableRanges: false, reloadedBefore: false), .native)
        XCTAssertEqual(HeldSongSeek.plan(knownTranscoded: false, serverAnswer: false, hasSeekableRanges: false, reloadedBefore: true), .native)
        // Reloaded once already, again no ranges and still no answer (the request
        // fails): a transcode the headers do not reveal. Remembered, so it ends there.
        XCTAssertEqual(HeldSongSeek.plan(knownTranscoded: false, serverAnswer: nil, hasSeekableRanges: false, reloadedBefore: true), .reload(remember: true))
        // Known to be transcoded (by the item, or by the server's answer since).
        XCTAssertEqual(HeldSongSeek.plan(knownTranscoded: true, serverAnswer: nil, hasSeekableRanges: true, reloadedBefore: false), .reload(remember: false))
        XCTAssertEqual(HeldSongSeek.plan(knownTranscoded: false, serverAnswer: true, hasSeekableRanges: false, reloadedBefore: false), .reload(remember: false))
    }
}
