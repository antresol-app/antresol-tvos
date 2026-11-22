import Foundation

// What a page does with the ways that watch: which run is under way (and for which title or episode),
// which way «Play» runs, and the rows of the menu next to it. Nothing here knows an addon or its words.

// MARK: - A run under way

/// A run of a way for one subject: the way, and the title, season and episode it was started for.
/// The library flag of a target is left out: it can change under a page (an episode gets downloaded)
/// without the run being another one.
public struct WayRunKey: Hashable, Sendable {
    /// `AddonWay.id`.
    public let wayId: String
    public let kind: String
    public let tmdbId: Int
    public let season: Int?
    public let episode: Int?

    public init(wayId: String, target: WayTarget) {
        self.wayId = wayId
        kind = target.kind
        tmdbId = target.tmdbId
        season = target.season
        episode = target.episode
    }

    /// Whether the run is for `target` itself: the same title, season and episode.
    public func isFor(_ target: WayTarget) -> Bool {
        kind == target.kind && tmdbId == target.tmdbId && season == target.season && episode == target.episode
    }
}

/// Which run is under way. One at a time, but only the button of that way on that subject shows it:
/// the same way on another episode, or on the title's own page button, is not busy.
public struct WayRunGate: Hashable, Sendable {
    public private(set) var current: WayRunKey?

    public init() {}

    /// Some run is under way: another press waits.
    public var isBusy: Bool { current != nil }

    /// `wayId`'s run for `target` is the one under way.
    public func isRunning(_ wayId: String, for target: WayTarget) -> Bool {
        current == WayRunKey(wayId: wayId, target: target)
    }

    /// Some way's run for `target` itself is the one under way.
    public func isRunning(for target: WayTarget) -> Bool {
        current?.isFor(target) == true
    }

    /// Takes the one slot; false when a run is already under way.
    @discardableResult
    public mutating func begin(_ key: WayRunKey) -> Bool {
        guard current == nil else { return false }
        current = key
        return true
    }

    /// Gives the slot back, if `key` holds it.
    public mutating func end(_ key: WayRunKey) {
        if current == key { current = nil }
    }
}

// MARK: - What «Play» runs

/// A short line under a way in the menu. The addons say only a label and a glyph, so the line comes
/// from the glyph (the protocol's own vocabulary), not from an addon or its words; the app words it.
public enum WayHint: String, Hashable, Sendable {
    /// A globe: a stream of the web, which opens at once.
    case startsRightAway
    /// A play triangle: a source that plays as it comes in.
    case playsWhileDownloading
}

extension AddonWay {
    /// The hint of this way's glyph; none for a glyph that says nothing about how it plays.
    public var hint: WayHint? {
        switch icon {
        case .globe: return .startsRightAway
        case .play: return .playsWhileDownloading
        case .download, .list: return nil
        }
    }
}

/// One row of the menu next to «Play»: a way that watches.
public struct WayMenuRow: Hashable, Identifiable, Sendable {
    public let way: AddonWay
    /// The way «Play» runs now (ticked).
    public let isDefault: Bool

    public var id: String { way.id }
    public var hint: WayHint? { way.hint }

    public init(way: AddonWay, isDefault: Bool) {
        self.way = way
        self.isDefault = isDefault
    }
}

/// The ways that watch a title, as «Play» and its menu show them: one row each, the default ticked.
public struct WayMenu: Hashable, Sendable {
    public let rows: [WayMenuRow]
    /// What «Play» runs: the way remembered for the title when it is still offered, else the first.
    public let defaultWay: AddonWay

    /// nil without a way that watches.
    public init?(ways: [AddonWay], remembered: String?) {
        let watching = ways.filter { $0.role == .watch }
        guard let first = watching.first else { return nil }
        let chosen = remembered.flatMap { id in watching.first { $0.id == id } } ?? first
        defaultWay = chosen
        rows = watching.map { WayMenuRow(way: $0, isDefault: $0.id == chosen.id) }
    }
}

/// The way a person chose to watch a title with, kept on this device (per profile): «Play» runs it
/// next time. Per title: an episode runs its show's way.
public final class WayDefaults: @unchecked Sendable {
    private let defaults: UserDefaults
    private let scope: String

    /// `scope` keeps profiles apart (the signed-in profile's id).
    public init(defaults: UserDefaults = .standard, scope: String = "") {
        self.defaults = defaults
        self.scope = scope
    }

    private func key(_ target: WayTarget) -> String {
        "antresol.wayDefault.\(scope).\(target.kind).\(target.tmdbId)"
    }

    /// The remembered way's `AddonWay.id` for the title, if any.
    public func remembered(for target: WayTarget) -> String? {
        defaults.string(forKey: key(target))
    }

    public func remember(_ wayId: String, for target: WayTarget) {
        defaults.set(wayId, forKey: key(target))
    }

    public func forget(for target: WayTarget) {
        defaults.removeObject(forKey: key(target))
    }

    /// The menu for `ways` (those that watch) on `target`; nil when none watches.
    public func menu(for ways: [AddonWay], target: WayTarget) -> WayMenu? {
        WayMenu(ways: ways, remembered: remembered(for: target))
    }
}
