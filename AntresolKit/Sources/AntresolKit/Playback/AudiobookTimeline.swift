import Foundation

/// Maps between the whole-book timeline used by the server (progress, chapters)
/// and positions inside the individual audiobook parts (§8.4).
public struct AudiobookTimeline: Hashable, Sendable {
    public struct Location: Hashable, Sendable {
        /// Index into the book's `files`.
        public var partIndex: Int
        /// Offset inside that part.
        public var offsetMs: Int
    }

    public let partDurationsMs: [Int]

    public init(files: [BookFile]) {
        partDurationsMs = files.map { max(0, $0.durationMs) }
    }

    public var totalMs: Int {
        partDurationsMs.reduce(0, +)
    }

    /// Whole-book start of each part.
    public func startMs(ofPart index: Int) -> Int {
        partDurationsMs.prefix(max(0, index)).reduce(0, +)
    }

    /// The part and in-part offset for a whole-book position. Positions past the
    /// end land at the end of the last part.
    public func locate(bookMs: Int) -> Location? {
        guard !partDurationsMs.isEmpty else { return nil }
        var start = 0
        for (index, duration) in partDurationsMs.enumerated() {
            if bookMs < start + duration || index == partDurationsMs.count - 1 {
                return Location(partIndex: index, offsetMs: min(max(0, bookMs - start), duration))
            }
            start += duration
        }
        return nil
    }

    /// The whole-book position of an offset inside a part.
    public func bookMs(partIndex: Int, offsetMs: Int) -> Int {
        startMs(ofPart: partIndex) + max(0, offsetMs)
    }

    /// The chapter playing at a whole-book position.
    public static func chapter(at bookMs: Int, in chapters: [Chapter]) -> Chapter? {
        chapters.last { $0.startMs <= bookMs } ?? chapters.first
    }

    /// Where "previous chapter" goes: the start of the current chapter, or of the one
    /// before when less than `restartWindowMs` of the current chapter has played.
    public static func previousChapterStart(from bookMs: Int, in chapters: [Chapter], restartWindowMs: Int = 3000) -> Int {
        let ordered = chapters.sorted { $0.startMs < $1.startMs }
        guard let index = ordered.lastIndex(where: { $0.startMs <= bookMs }) else { return 0 }
        if bookMs - ordered[index].startMs > restartWindowMs || index == 0 {
            return ordered[index].startMs
        }
        return ordered[index - 1].startMs
    }

    /// Where "next chapter" goes, or nil in the last chapter.
    public static func nextChapterStart(from bookMs: Int, in chapters: [Chapter]) -> Int? {
        chapters.map(\.startMs).sorted().first { $0 > bookMs }
    }

    /// The end of the chapter playing at `bookMs` (the book's end when unknown).
    public static func chapterEnd(at bookMs: Int, in chapters: [Chapter], totalMs: Int) -> Int {
        guard let chapter = chapter(at: bookMs, in: chapters), chapter.endMs > bookMs else { return totalMs }
        return chapter.endMs
    }
}

/// Where to resume playback, following the web app's rules.
public enum ResumePolicy {
    /// Video resume point in seconds: the stored position unless finished.
    public static func videoStartSec(_ progress: PlaybackProgress?) -> Double {
        guard let progress, progress.exists, !progress.finished else { return 0 }
        return Double(progress.positionMs) / 1000
    }

    /// Audiobook resume point on the whole-book timeline: restart from 0 when finished,
    /// at ≥ 98 % or with ≤ 30 s left.
    public static func audiobookStartMs(positionMs: Int, durationMs: Int, finished: Bool) -> Int {
        guard !finished, positionMs > 0 else { return 0 }
        if durationMs > 0 {
            if Double(positionMs) >= 0.98 * Double(durationMs) || durationMs - positionMs <= 30_000 {
                return 0
            }
        }
        return positionMs
    }

    public static func audiobookStartMs(_ book: BookDetail) -> Int {
        guard let progress = book.progress else { return 0 }
        return audiobookStartMs(
            positionMs: progress.positionMs,
            durationMs: book.durationMs > 0 ? book.durationMs : progress.durationMs,
            finished: progress.finished
        )
    }
}
