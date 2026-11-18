import Foundation

/// Skip segments of a file (`/api/play` `segments`): the recap, the intro and the credits, in
/// seconds on the file timeline. The player offers «Пропустить пересказ / вступление» while
/// playback is inside one, and «Следующая серия» (filling over 10 s of playing, then playing it) at the
/// credits. The rules are the web player's (`skipSegments.ts`, `SkipControls.tsx`) and the
/// Android app's (`SkipSegments`, `SkipTracker`).
public enum SkipSegments {
    public static let recap = "recap"
    public static let intro = "intro"
    public static let credits = "credits"
    static let kinds: Set<String> = [recap, intro, credits]

    /// Shorter segments are not offered (a stray chapter mark).
    public static let minSegmentSec: Double = 3
    /// The pill shows this long after playback enters a segment, even with the controls hidden.
    public static let pillAloneSec: Double = 8
    /// «Следующая серия» fills over this long, then plays it.
    public static let nextCountdownSec: Double = 10
    /// A gap between two position ticks longer than this is a stall, not playback: it counts
    /// for no more than this much toward the countdown.
    public static let maxTickGapSec: Double = 1
    /// Credits ending this long before the file does leave a scene after them: no autoplay.
    public static let postCreditsSec: Double = 20
    /// The note after an automatic skip («Вступление пропущено · Вернуть») stays this long.
    public static let skippedNoteSec: Double = 6
    /// The system's Up Next panel presents itself when playback reaches the credits' start;
    /// it may still do so this long after.
    public static let upNextPanelGraceSec: Double = 1.5

    /// The segments the player uses: known kinds, at least `minSegmentSec`, in time order.
    public static func usable(_ segments: [PlaySegment]) -> [PlaySegment] {
        segments
            .filter { kinds.contains($0.kind) && $0.startSec.isFinite && $0.endSec.isFinite && $0.endSec - $0.startSec >= minSegmentSec }
            .sorted { $0.startSec < $1.startSec }
    }

    /// The segment playback is in at `time` (its last quarter second counts as out: a seek
    /// to its end lands there).
    public static func at(_ segments: [PlaySegment], time: Double) -> PlaySegment? {
        segments.first { time >= $0.startSec && time < $0.endSec - 0.25 }
    }

    /// A scene follows the credits: they end well before the file does.
    public static func postCreditsScene(_ credits: PlaySegment, durationSec: Double) -> Bool {
        durationSec > 0 && durationSec - credits.endSec > postCreditsSec
    }

    /// The credits run to the end of the file: skipping them ends it.
    public static func creditsToEnd(_ credits: PlaySegment, durationSec: Double) -> Bool {
        durationSec <= 0 || durationSec - credits.endSec < 1
    }

    /// The system's Up Next panel is about to present itself (a proposal waits and playback
    /// has only just reached the credits' start). Its «Следующая серия» is then not repeated
    /// as a pill over the video; credits entered later (a resume, a seek) get the pill.
    public static func upNextPanelPending(position: Double, creditsStartSec: Double, proposalAttached: Bool) -> Bool {
        proposalAttached && position < creditsStartSec + upNextPanelGraceSec
    }

    /// How far «Следующая серия» has filled (0…1) after `playedSec` of playback in the credits.
    /// Playing time, not file position: a seek forward inside the credits does not fill it.
    public static func countdown(playedSec: Double) -> Double {
        min(1, max(0, playedSec / nextCountdownSec))
    }
}

/// What a skip pill (or the player by itself) does.
public enum SkipAction: Hashable, Sendable {
    /// Seek to this file position (seconds).
    case seek(toSec: Double)
    /// On to the next episode.
    case next
    /// The credits run to the end and are skipped: as if the file ended.
    case end
}

/// The pill over the video for the segment playback is in.
public enum SkipPill: Hashable, Sendable {
    /// «Пропустить пересказ / вступление / титры» (`kind`). `alone`: within
    /// `SkipSegments.pillAloneSec` of the segment's start, when it shows with the controls
    /// hidden too (later only with them).
    case skip(kind: String, alone: Bool, action: SkipAction)
    /// «Следующая серия» beside «Смотреть титры» at the credits of an episode with a next
    /// one. With `countdown` it fills (`fill`, 0…1) and then plays it; never when a scene
    /// follows the credits.
    case next(fill: Double, countdown: Bool)

    /// Whether the pill is on screen now.
    public func isShown(controlsVisible: Bool) -> Bool {
        switch self {
        case .skip(_, let alone, _): return alone || controlsVisible
        case .next: return true
        }
    }
}

/// A recap or intro the player skipped by itself; «Вернуть» seeks back to `backSec`.
public struct SkipNote: Hashable, Sendable {
    public var kind: String
    public var backSec: Double

    public init(kind: String, backSec: Double) {
        self.kind = kind
        self.backSec = backSec
    }
}

/// The skip state of one file: which pill shows at a position, and what «Пропускать сам»
/// does by itself, once per segment (a segment skipped by itself, or taken back, is never
/// skipped again in this file). The player calls `step` on its position ticks and runs
/// `Step.auto`.
public struct SkipTracker: Sendable {
    public let segments: [PlaySegment]

    /// «Смотреть титры» was chosen: no «Следующая серия» and no automatic next for this file.
    public var creditsDismissed = false

    private var autoDone: Set<String> = []
    private var entered: (key: String, at: TimeInterval)?
    /// Playing time spent in the segment entered, which fills «Следующая серия», and the
    /// clock of the last tick that was playing (nil after a pause, a stall or a segment change).
    private var playedSec: Double = 0
    private var lastPlayingTick: TimeInterval?
    private var nexted = false

    public init(segments: [PlaySegment]) {
        self.segments = SkipSegments.usable(segments)
    }

    /// The file has a usable segment (the «Пропускать сам» menu shows only then).
    public var hasSegments: Bool { !segments.isEmpty }

    /// The usable credits, if any.
    public var credits: PlaySegment? { segments.first { $0.kind == SkipSegments.credits } }

    /// What the player does by itself.
    public enum Auto: Hashable, Sendable {
        /// A recap or intro skipped by itself: seek to `toSec` and show `note`.
        case skipped(toSec: Double, note: SkipNote)
        case next
        case end
    }

    /// What shows (`pill`) and what the player does by itself now (`auto`, at most once).
    public struct Step: Hashable, Sendable {
        public var pill: SkipPill?
        public var auto: Auto?
    }

    /// The state at `time` (file seconds) at `now` (a monotonic clock, seconds, for the
    /// pill's 8 s and the countdown's playing time, which counts only ticks with `playing`).
    /// `durationSec` is the file's (0: unknown), `hasNext`: an episode follows,
    /// `autoplayNext`: the device plays it after a countdown, `autoSkip`: the profile's
    /// «Пропускать сам».
    public mutating func step(
        time: Double, now: TimeInterval, playing: Bool, durationSec: Double,
        hasNext: Bool, autoplayNext: Bool, autoSkip: AutoSkip
    ) -> Step {
        guard let active = SkipSegments.at(segments, time: time) else {
            entered = nil
            lastPlayingTick = nil
            return Step(pill: nil, auto: nil)
        }
        let key = "\(active.kind):\(active.startSec)"
        if entered?.key != key {
            entered = (key, now)
            playedSec = 0
            lastPlayingTick = nil
        }
        let enteredAt = entered!
        // Real playback time since entry: a seek inside the segment moves the position, not this.
        if playing {
            if let last = lastPlayingTick {
                playedSec += min(max(0, now - last), SkipSegments.maxTickGapSec)
            }
            lastPlayingTick = now
        } else {
            lastPlayingTick = nil
        }

        var auto: Auto?
        if playing, !autoDone.contains(key) {
            let kind = active.kind
            if kind != SkipSegments.credits, autoSkip.isOn(kind) {
                autoDone.insert(key)
                return Step(pill: nil, auto: .skipped(toSec: active.endSec, note: SkipNote(kind: kind, backSec: active.startSec)))
            }
            if kind == SkipSegments.credits, autoSkip.credits, !creditsDismissed,
               !SkipSegments.postCreditsScene(active, durationSec: durationSec) {
                autoDone.insert(key)
                auto = hasNext ? next() : .end
            }
        }

        let alone = now - enteredAt.at < SkipSegments.pillAloneSec
        guard active.kind == SkipSegments.credits else {
            return Step(pill: .skip(kind: active.kind, alone: alone, action: .seek(toSec: active.endSec)), auto: auto)
        }
        if hasNext {
            guard !creditsDismissed else { return Step(pill: nil, auto: auto) }
            let countdown = autoplayNext && !SkipSegments.postCreditsScene(active, durationSec: durationSec)
            let fill = countdown ? SkipSegments.countdown(playedSec: playedSec) : 0
            if countdown, fill >= 1, auto == nil { auto = next() }
            return Step(pill: .next(fill: fill, countdown: countdown), auto: auto)
        }
        let action: SkipAction = SkipSegments.creditsToEnd(active, durationSec: durationSec) ? .end : .seek(toSec: active.endSec)
        return Step(pill: .skip(kind: active.kind, alone: alone, action: action), auto: auto)
    }

    /// «Следующая серия» pressed or the countdown ran out: true the first time only.
    public mutating func takeNext() -> Bool {
        if nexted { return false }
        nexted = true
        return true
    }

    private mutating func next() -> Auto? {
        takeNext() ? .next : nil
    }
}
