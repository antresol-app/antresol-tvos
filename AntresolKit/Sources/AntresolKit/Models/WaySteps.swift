import Foundation

// Choosing step by step, running a way and the state of what it started (`x/app/step`,
// `x/app/run`, `x/app/state`).

/// One row of a step: a choice the person can make.
public struct WayRow: Decodable, Hashable, Identifiable, Sendable {
    /// Opaque: the next step or the run gets it back.
    public var ref: String
    public var label: String
    /// A second line.
    public var detail: String?
    public var badges: [String]
    /// The person's last choice.
    public var current: Bool
    /// Choosing it runs the way (`true`), or opens the next step (`false`).
    public var isFinal: Bool

    public var id: String { ref }

    public init(ref: String, label: String, detail: String? = nil, badges: [String] = [], current: Bool = false, isFinal: Bool = true) {
        self.ref = ref
        self.label = label
        self.detail = detail
        self.badges = badges
        self.current = current
        self.isFinal = isFinal
    }

    enum CodingKeys: String, CodingKey {
        case ref, label, detail, badges, current
        case isFinal = "final"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ref = try c.decode(String.self, forKey: .ref)
        label = c.value(.label, default: "")
        let second: String? = c.optional(.detail)
        detail = second.flatMap { $0.isEmpty ? nil : $0 }
        badges = c.value(.badges, default: [])
        current = c.value(.current, default: false)
        isFinal = c.value(.isFinal, default: true)
    }
}

/// `POST x/app/step`: a sheet's worth of choices.
public struct WayStep: Decodable, Hashable, Sendable {
    public var title: String
    public var rows: [WayRow]
    /// Text above the list.
    public var note: String?
    /// Text when there are no rows.
    public var empty: String?

    public init(title: String = "", rows: [WayRow] = [], note: String? = nil, empty: String? = nil) {
        self.title = title
        self.rows = rows
        self.note = note
        self.empty = empty
    }

    enum CodingKeys: String, CodingKey { case title, rows, note, empty }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = c.value(.title, default: "")
        // A malformed row drops that row only; a row listed twice shows once.
        let entries: [Lenient<WayRow>] = c.value(.rows, default: [])
        var seen = Set<String>()
        rows = entries.compactMap(\.value).filter { !$0.label.isEmpty && seen.insert($0.ref).inserted }
        let above: String? = c.optional(.note)
        note = above.flatMap { $0.isEmpty ? nil : $0 }
        let none: String? = c.optional(.empty)
        empty = none.flatMap { $0.isEmpty ? nil : $0 }
    }
}

/// How often and where the player reports a directly played way's position.
public struct WayProgressSpec: Hashable, Sendable {
    public static let defaultPath = "x/app/progress"
    public static let defaultEvery: Double = 10

    public var path: String
    /// Seconds.
    public var every: Double

    public init(path: String = WayProgressSpec.defaultPath, every: Double = WayProgressSpec.defaultEvery) {
        self.path = path
        self.every = every
    }

    /// The answer's `progress`, or the protocol's own values. A path outside `x/app/` is never
    /// used: the app writes progress only there.
    init(raw: RawProgress?) {
        let value = raw?.path?.trimmingCharacters(in: .whitespaces) ?? ""
        let safe = value.hasPrefix("x/app/") && !value.contains("..") && !value.contains("?") && !value.contains("#")
        path = safe ? value : Self.defaultPath
        // Often enough to matter, rarely enough to be cheap.
        every = min(max(raw?.every ?? Self.defaultEvery, 2), 60)
    }

    struct RawProgress: Decodable {
        var path: String?
        var every: Double?

        enum CodingKeys: String, CodingKey { case path, every }

        init(path: String?, every: Double?) {
            self.path = path
            self.every = every
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            path = c.optional(.path)
            every = c.optional(.every)
        }
    }
}

/// `{"play": PlayResponse}`: play the way's own stream. The answer is the `/api/play` one, with the
/// addon's `session` and `progress` beside its fields.
public struct WayPlay: Hashable, Sendable {
    public var response: PlayResponse
    /// Closed with `DELETE x/app/play/{session}` when the player closes.
    public var session: String?
    public var progress: WayProgressSpec

    public init(response: PlayResponse, session: String? = nil, progress: WayProgressSpec = WayProgressSpec()) {
        self.response = response
        self.session = session
        self.progress = progress
    }
}

/// The answer of `POST x/app/run`: exactly one of these.
public enum WayRunResult: Decodable, Hashable, Sendable {
    /// Play through the core's input player (`/api/play/input/{id}`).
    case input(String)
    /// Play the stream directly.
    case play(WayPlay)
    /// Done; the text is shown as a notice.
    case done(String)
    /// The way has no remembered choice: open the chooser.
    case pick

    enum CodingKeys: String, CodingKey { case input, play, done, pick, session, progress }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let id: String = c.optional(.input), !id.isEmpty {
            self = .input(id)
        } else if c.contains(.play), let nested = try? c.superDecoder(forKey: .play),
                  let response = try? PlayResponse(from: nested) {
            // `session` and `progress` come with the stream's fields, or beside them.
            let inner = try? nested.container(keyedBy: CodingKeys.self)
            let session: String? = inner?.optional(.session) ?? c.optional(.session)
            let progress: WayProgressSpec.RawProgress? = inner?.optional(.progress) ?? c.optional(.progress)
            self = .play(WayPlay(
                response: response,
                session: session.flatMap { $0.isEmpty ? nil : $0 },
                progress: WayProgressSpec(raw: progress)
            ))
        } else if let text: String = c.optional(.done) {
            self = .done(text)
        } else if let pick: Bool = c.optional(.pick), pick {
            self = .pick
        } else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "no run result"))
        }
    }
}

/// One way's state on a title (`GET x/app/state`): what it started and how far it is.
public struct WayState: Decodable, Hashable, Sendable {
    public var active: Bool
    /// 0...1 when known.
    public var fraction: Double?
    /// «Скачано 40%».
    public var text: String?
    /// The way can be cancelled while it is active.
    public var cancel: Bool

    public init(active: Bool = false, fraction: Double? = nil, text: String? = nil, cancel: Bool = false) {
        self.active = active
        self.fraction = fraction
        self.text = text
        self.cancel = cancel
    }

    enum CodingKeys: String, CodingKey { case active, fraction, text, cancel }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        active = c.value(.active, default: false)
        let part: Double? = c.optional(.fraction)
        fraction = part.map { min(max($0, 0), 1) }
        let words: String? = c.optional(.text)
        text = words.flatMap { $0.isEmpty ? nil : $0 }
        cancel = c.value(.cancel, default: false)
    }
}

/// `{"ways": {"<wayId>": WayState}}`.
public struct WayStates: Decodable, Sendable {
    public var ways: [String: WayState]

    enum CodingKeys: String, CodingKey { case ways }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ways = c.value(.ways, default: [:])
    }
}

/// Polling the states of what ways started.
public enum WayStatePolling {
    /// Seconds between two asks while any way is active.
    public static let interval: Double = 5

    /// Whether to ask again: only while something is active.
    public static func shouldContinue(_ states: [String: WayState]) -> Bool {
        states.values.contains { $0.active }
    }
}

// MARK: - Request bodies

/// Body of `POST x/app/step`.
public struct WayStepRequest: Encodable, Hashable, Sendable {
    public var way: String
    public var kind: String
    public var tmdbId: Int
    public var season: Int?
    public var episode: Int?
    /// From the row chosen in the previous step; none for the first step.
    public var ref: String?

    public init(way: String, target: WayTarget, ref: String? = nil) {
        self.way = way
        self.kind = target.kind
        self.tmdbId = target.tmdbId
        self.season = target.season
        self.episode = target.episode
        self.ref = ref
    }
}

/// Body of `POST x/app/run`.
public struct WayRunRequest: Encodable, Hashable, Sendable {
    public var way: String
    public var kind: String
    public var tmdbId: Int
    public var season: Int?
    public var episode: Int?
    public var ref: String?
    public var startSec: Double?
    /// The tallest picture this screen shows.
    public var maxHeight: Int?
    /// «Right away»: no chooser, the addon takes the remembered or best choice.
    public var quick: Bool?
    /// The stream's link went stale: fetch a fresh one for the same choice.
    public var refresh: Bool?

    public init(
        way: String, target: WayTarget, ref: String? = nil, startSec: Double? = nil,
        maxHeight: Int? = nil, quick: Bool = false, refresh: Bool = false
    ) {
        self.way = way
        self.kind = target.kind
        self.tmdbId = target.tmdbId
        self.season = target.season
        self.episode = target.episode
        self.ref = ref
        self.startSec = startSec.flatMap { $0 > 0 ? $0 : nil }
        self.maxHeight = maxHeight
        self.quick = quick ? true : nil
        self.refresh = refresh ? true : nil
    }
}

/// Body of `POST x/app/cancel`.
public struct WayCancelRequest: Encodable, Hashable, Sendable {
    public var way: String
    public var kind: String
    public var tmdbId: Int
    public var season: Int?

    public init(way: String, target: WayTarget) {
        self.way = way
        self.kind = target.kind
        self.tmdbId = target.tmdbId
        self.season = target.season
    }
}

/// Body of `PUT x/app/progress`.
public struct WayProgressUpdate: Encodable, Hashable, Sendable {
    public var session: String
    public var way: String
    public var kind: String
    public var tmdbId: Int
    public var season: Int?
    public var episode: Int?
    public var positionMs: Int
    public var durationMs: Int
    public var finished: Bool?

    public init(session: String, way: String, target: WayTarget, positionMs: Int, durationMs: Int, finished: Bool = false) {
        self.session = session
        self.way = way
        self.kind = target.kind
        self.tmdbId = target.tmdbId
        self.season = target.season
        self.episode = target.episode
        self.positionMs = positionMs
        self.durationMs = durationMs
        self.finished = finished ? true : nil
    }
}

/// `{"done": "..."}` of `POST x/app/cancel`.
struct WayDone: Decodable {
    var done: String?

    enum CodingKeys: String, CodingKey { case done }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        done = c.optional(.done)
    }
}
