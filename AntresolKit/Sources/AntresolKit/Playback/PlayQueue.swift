import Foundation

/// Repeat modes of the music player.
public enum RepeatMode: String, CaseIterable, Sendable {
    case off
    /// Start the queue over after the last item.
    case all
    /// Play the current item again.
    case one

    /// Off → All → One → Off, the order a single repeat button cycles through.
    public var next: RepeatMode {
        switch self {
        case .off: return .all
        case .all: return .one
        case .one: return .off
        }
    }
}

/// A play queue with shuffle and repeat, independent of any player.
///
/// The queue keeps the order it was built in (`original`) and the order it plays in
/// (`items`). Turning shuffle on keeps the current item first and shuffles the rest;
/// turning it off restores the original order and keeps playing the same item.
public struct PlayQueue<Element: Hashable & Sendable>: Sendable {
    /// Queue entries carry a unique id so the same song can appear twice.
    public struct Entry: Hashable, Identifiable, Sendable {
        public let id: UUID
        public let element: Element

        public init(_ element: Element, id: UUID = UUID()) {
            self.id = id
            self.element = element
        }
    }

    /// Entries in play order.
    public private(set) var items: [Entry]
    /// Index of the current entry in `items`; nil when the queue is empty.
    public private(set) var currentIndex: Int?
    public private(set) var isShuffled = false
    public var repeatMode: RepeatMode = .off
    /// Entries in the order the queue was built and added to.
    private var original: [Entry]

    public init(_ elements: [Element] = [], startAt index: Int = 0, shuffled: Bool = false) {
        let entries = elements.map { Entry($0) }
        items = entries
        original = entries
        currentIndex = entries.isEmpty ? nil : min(max(0, index), entries.count - 1)
        if shuffled {
            setShuffle(true)
        }
    }

    public var isEmpty: Bool { items.isEmpty }
    public var count: Int { items.count }

    public var current: Entry? {
        currentIndex.map { items[$0] }
    }

    /// Entries after the current one, in play order (not counting a repeat-all wrap).
    public var upcoming: ArraySlice<Entry> {
        guard let currentIndex else { return [] }
        return items[(currentIndex + 1)...]
    }

    /// The index that plays when the current item ends by itself.
    public var indexAfterCurrentEnds: Int? {
        guard let currentIndex else { return nil }
        if repeatMode == .one { return currentIndex }
        return indexAfter(currentIndex)
    }

    /// The index the "next" button moves to. It skips ahead even with repeat-one.
    public var nextIndex: Int? {
        currentIndex.flatMap(indexAfter)
    }

    /// The index the "previous" button moves to; nil at the start of the queue without
    /// repeat-all (callers restart the current item then).
    public var previousIndex: Int? {
        guard let currentIndex else { return nil }
        if currentIndex > 0 { return currentIndex - 1 }
        return repeatMode == .all && items.count > 1 ? items.count - 1 : nil
    }

    /// Moves to `index` in play order.
    @discardableResult
    public mutating func move(to index: Int) -> Entry? {
        guard items.indices.contains(index) else { return nil }
        currentIndex = index
        return items[index]
    }

    /// Moves to the entry with `id`.
    @discardableResult
    public mutating func move(toEntry id: UUID) -> Entry? {
        items.firstIndex { $0.id == id }.flatMap { move(to: $0) }
    }

    /// Turns shuffle on or off. The current entry keeps playing in both cases.
    public mutating func setShuffle(_ on: Bool) {
        var generator = SystemRandomNumberGenerator()
        setShuffle(on, using: &generator)
    }

    public mutating func setShuffle<G: RandomNumberGenerator>(_ on: Bool, using generator: inout G) {
        let current = current
        if on {
            var rest = items.filter { $0.id != current?.id }
            rest.shuffle(using: &generator)
            items = (current.map { [$0] } ?? []) + rest
            currentIndex = items.isEmpty ? nil : 0
        } else {
            items = original
            currentIndex = current.flatMap { entry in items.firstIndex { $0.id == entry.id } } ?? (items.isEmpty ? nil : 0)
        }
        isShuffled = on
    }

    /// Inserts elements right after the current entry ("Play Next").
    public mutating func insertNext(_ elements: [Element]) {
        let entries = elements.map { Entry($0) }
        guard let currentIndex else {
            append(contentsOf: elements)
            return
        }
        items.insert(contentsOf: entries, at: currentIndex + 1)
        let originalPosition = original.firstIndex { $0.id == items[currentIndex].id }.map { $0 + 1 } ?? original.count
        original.insert(contentsOf: entries, at: originalPosition)
    }

    /// Adds elements at the end ("Add to Queue").
    public mutating func append(contentsOf elements: [Element]) {
        let entries = elements.map { Entry($0) }
        items.append(contentsOf: entries)
        original.append(contentsOf: entries)
        if currentIndex == nil, !items.isEmpty {
            currentIndex = 0
        }
    }

    /// Adds more of the list the queue was built from (e.g. later pages of the song
    /// library). They go to the end of the original order; while shuffled they are
    /// mixed into the entries still to come, as if they had been there from the start.
    public mutating func extend(with elements: [Element]) {
        var generator = SystemRandomNumberGenerator()
        extend(with: elements, using: &generator)
    }

    public mutating func extend<G: RandomNumberGenerator>(with elements: [Element], using generator: inout G) {
        guard isShuffled, let currentIndex else {
            return append(contentsOf: elements)
        }
        let entries = elements.map { Entry($0) }
        original.append(contentsOf: entries)
        for entry in entries {
            items.insert(entry, at: Int.random(in: (currentIndex + 1)...items.count, using: &generator))
        }
    }

    /// Removes an upcoming entry. The current entry cannot be removed.
    public mutating func remove(entry id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }), index != currentIndex else { return }
        items.remove(at: index)
        original.removeAll { $0.id == id }
        if let currentIndex, index < currentIndex {
            self.currentIndex = currentIndex - 1
        }
    }

    private func indexAfter(_ index: Int) -> Int? {
        if index + 1 < items.count { return index + 1 }
        return repeatMode == .all && !items.isEmpty ? 0 : nil
    }
}

/// Counts actually played time for one track and says when to scrobble it
/// (`POST /api/music/plays`), once per play.
public struct ScrobbleTracker: Sendable {
    public let trackId: Int
    public let thresholdSeconds: Double
    public private(set) var playedSeconds: Double = 0
    public private(set) var isRecorded = false
    private var lastPosition: Double?

    public init(trackId: Int, durationMs: Int) {
        self.trackId = trackId
        thresholdSeconds = ScrobblePolicy.thresholdSeconds(durationMs: durationMs)
    }

    /// Feeds the current position while playing. Jumps (seeks) are not counted as
    /// listening. Returns true exactly once, when the play should be recorded.
    public mutating func advance(to position: Double) -> Bool {
        defer { lastPosition = position }
        guard let last = lastPosition else { return false }
        let delta = position - last
        // Periodic ticks are about half a second apart (more at higher speeds); anything
        // larger or negative is a seek.
        if delta > 0, delta <= 5 {
            playedSeconds += delta
        }
        guard !isRecorded, playedSeconds >= thresholdSeconds else { return false }
        isRecorded = true
        return true
    }

    /// Forgets the last position, e.g. after a seek or a pause, so the jump is not counted.
    public mutating func resetPosition() {
        lastPosition = nil
    }
}
