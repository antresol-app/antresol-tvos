import Foundation

// «Семья»: where the other profiles are in a title (the server's `GET /api/items/{id}/family`, the
// web's FamilyProgress), and «Продолжить с их места»: `POST /api/progress/{itemId}/adopt` copies
// their position into this profile's own progress and never touches theirs. The server lists
// nobody for a kid, and nothing when nobody else has progress there.
//
// The words are the app's (it has the catalogs); the kit says what to put in them: a place is a
// case with its numbers, not a sentence.

/// One other profile's place in an item: the movie, the episode of a series (the page's own or the
/// one the profile is at) or its next episode. As `family.go`'s `FamilyMember` sends it.
public struct FamilyMember: Decodable, Hashable, Identifiable, Sendable {
    public var userId: Int
    public var name: String
    /// A device's managed account names its person («Гостиная · Папа»); "" for a person's own profile.
    public var ownerName: String
    public var avatar: String
    public var photo: String
    public var isKid: Bool
    /// Where the position is: the movie, or the episode of a series.
    public var itemId: Int
    public var positionMs: Int
    public var durationMs: Int
    /// 0...1 of `itemId`.
    public var fraction: Double
    public var finished: Bool
    public var locator: String
    public var updatedAt: Date?
    public var season: Int?
    public var episode: Int?
    /// The episode's title.
    public var title: String
    /// A series' next episode: `itemId` is the one after the last finished, not started.
    public var next: Bool
    /// A series' finished and total regular episodes.
    public var done: Int
    public var total: Int

    public var id: Int { userId }

    public init(
        userId: Int, name: String, ownerName: String = "", avatar: String = "grad-1", photo: String = "", isKid: Bool = false,
        itemId: Int, positionMs: Int = 0, durationMs: Int = 0, fraction: Double = 0, finished: Bool = false,
        locator: String = "", updatedAt: Date? = nil, season: Int? = nil, episode: Int? = nil, title: String = "",
        next: Bool = false, done: Int = 0, total: Int = 0
    ) {
        self.userId = userId
        self.name = name
        self.ownerName = ownerName
        self.avatar = avatar
        self.photo = photo
        self.isKid = isKid
        self.itemId = itemId
        self.positionMs = positionMs
        self.durationMs = durationMs
        self.fraction = fraction
        self.finished = finished
        self.locator = locator
        self.updatedAt = updatedAt
        self.season = season
        self.episode = episode
        self.title = title
        self.next = next
        self.done = done
        self.total = total
    }

    enum CodingKeys: String, CodingKey {
        case userId, name, ownerName, avatar, photo, isKid, itemId, positionMs, durationMs, fraction, finished
        case locator, updatedAt, season, episode, title, next, done, total
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        userId = try c.decode(Int.self, forKey: .userId)
        itemId = try c.decode(Int.self, forKey: .itemId)
        name = c.value(.name, default: "")
        ownerName = c.value(.ownerName, default: "")
        avatar = c.value(.avatar, default: "")
        photo = c.value(.photo, default: "")
        isKid = c.value(.isKid, default: false)
        positionMs = c.value(.positionMs, default: 0)
        durationMs = c.value(.durationMs, default: 0)
        fraction = c.value(.fraction, default: 0)
        finished = c.value(.finished, default: false)
        locator = c.value(.locator, default: "")
        let stamp: String? = c.optional(.updatedAt)
        updatedAt = Timestamp.parse(stamp)
        season = c.optional(.season)
        episode = c.optional(.episode)
        title = c.value(.title, default: "")
        next = c.value(.next, default: false)
        done = c.value(.done, default: 0)
        total = c.value(.total, default: 0)
    }

    public var avatarPreset: AvatarPreset { AvatarPreset(value: avatar) }

    /// The name in the list: «Гостиная · Папа» for a device's account, else the profile's.
    public var listName: String { ownerName.isEmpty ? name : "\(name) · \(ownerName)" }
}

/// What the page is: the labels and the jump depend on it. A season's page is its series'.
public enum FamilyKind: Hashable, Sendable {
    case movie, episode, series

    public init?(_ kind: ItemKind) {
        switch kind {
        case .movie: self = .movie
        case .episode: self = .episode
        case .series, .season: self = .series
        default: return nil
        }
    }
}

/// An episode's name in a place: «С2 Э5», or «Спецвыпуск 3» for season 0.
public struct FamilyCode: Equatable, Sendable {
    public var season: Int
    public var episode: Int
    public var isSpecial: Bool { season == 0 }
}

/// Where a profile is, in what the words are made of.
public enum FamilyPlace: Equatable, Sendable {
    /// A movie or an episode seen to the end.
    case watched
    /// Every episode of a series seen.
    case allWatched
    /// «Далее: С1 Э2»: the next episode, not started.
    case upNext(FamilyCode)
    /// «С1 Э2 · 17 мин»; `minutes` 0 is the code alone.
    case episode(FamilyCode, minutes: Int)
    /// «34 мин из 1 ч 50 мин» (the position is in whole minutes, or the clock «0:34» under a minute);
    /// without a known length (`durationMinutes` 0) the position alone, and nothing under a minute.
    case time(positionMinutes: Int, clock: String, durationMinutes: Int)
}

/// The jump button's words, or `none` when there is nothing to continue (finished).
public enum FamilyJump: Equatable, Sendable {
    case none
    /// «Смотреть С1 Э2»: an episode from its start.
    case watchEpisode(FamilyCode)
    /// «С1 Э2 с 17:00».
    case watchEpisodeAt(FamilyCode, clock: String)
    /// «Смотреть с 33:20».
    case watchAt(clock: String)
}

/// When a profile was last there, in what the words are made of.
public enum FamilyWhen: Equatable, Sendable {
    case now
    case minutes(Int)
    case hours(Int)
    case yesterday
    case date(Date)

    /// As the web's `ago`: seconds, minutes, hours, yesterday, then the date.
    public static func since(_ date: Date?, now: Date = Date()) -> FamilyWhen? {
        guard let date else { return nil }
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 60 { return .now }
        if seconds < 3600 { return .minutes(Int(seconds / 60)) }
        if seconds < 86400 { return .hours(Int(seconds / 3600)) }
        if seconds < 2 * 86400 { return .yesterday }
        return .date(date)
    }
}

extension FamilyMember {
    /// Whole minutes, as the web's `humanMinutes` rounds them; 0 for under half a minute.
    static func wholeMinutes(_ ms: Int) -> Int {
        max(0, Int((Double(ms) / 60_000).rounded()))
    }

    /// «34:12», «1:02:03».
    public static func clock(seconds: Double) -> String {
        let s = max(0, Int(seconds.isFinite ? seconds : 0))
        let h = s / 3600, m = (s % 3600) / 60
        let ss = String(format: "%02d", s % 60)
        return h > 0 ? "\(h):\(String(format: "%02d", m)):\(ss)" : "\(m):\(ss)"
    }

    /// The episode's name for this member.
    public var code: FamilyCode { FamilyCode(season: season ?? 0, episode: episode ?? 0) }

    /// The ring around the avatar: a series' share done, else the item's.
    public var ring: Double {
        if finished { return 1 }
        if total > 0 { return min(1, Double(done) / Double(total)) }
        return min(1, max(0, fraction))
    }

    /// Where the member is.
    public func place(_ kind: FamilyKind) -> FamilyPlace {
        if finished { return kind == .series ? .allWatched : .watched }
        switch kind {
        case .series:
            return next ? .upNext(code) : .episode(code, minutes: Self.wholeMinutes(positionMs))
        case .movie, .episode:
            return .time(
                positionMinutes: Self.wholeMinutes(positionMs), clock: Self.clock(seconds: Double(positionMs) / 1000),
                durationMinutes: durationMs > 0 ? Self.wholeMinutes(durationMs) : 0
            )
        }
    }

    /// What the button that continues from here says.
    public func jump(_ kind: FamilyKind) -> FamilyJump {
        if finished { return .none }
        let at = Self.clock(seconds: Double(positionMs) / 1000)
        switch kind {
        case .series:
            return next || positionMs <= 0 ? .watchEpisode(code) : .watchEpisodeAt(code, clock: at)
        case .movie, .episode:
            return positionMs > 0 ? .watchAt(clock: at) : .none
        }
    }

    /// Whether continuing from here first takes this member's position as the profile's own (a
    /// next episode, or one not started, just starts).
    public var adopts: Bool { !finished && !next && (positionMs > 0 || !locator.isEmpty) }

    /// Whether the member is at a place of `itemId` to look at: started there, not finished.
    public func hasPlace(in itemId: Int) -> Bool {
        self.itemId == itemId && !finished && (positionMs > 0 || fraction > 0)
    }
}

/// The folded line: the faces (a few, then «+N»), who is where and how many others.
public struct FamilyLine: Equatable, Sendable {
    /// How many faces the folded line shows before «+N».
    public static let faces = 4

    public var members: [FamilyMember]
    public var kind: FamilyKind

    /// nil when nobody else has progress: nothing is shown then.
    public init?(_ members: [FamilyMember], kind: FamilyKind) {
        guard !members.isEmpty else { return nil }
        self.members = members
        self.kind = kind
    }

    public var shown: [FamilyMember] { Array(members.prefix(Self.faces)) }
    /// «+N» after the faces.
    public var hiddenFaces: Int { max(0, members.count - Self.faces) }
    /// The newest profile: «Мама · С1 Э2 · 17 мин».
    public var first: FamilyMember { members[0] }
    public var place: FamilyPlace { first.place(kind) }
    /// «ещё 2».
    public var more: Int { members.count - 1 }
    /// Whether any row of the list has something to continue.
    public var hasJump: Bool { members.contains { $0.jump(kind) != .none } }
}

/// «Peeking» at another profile's place in the player: until the player plays on there, the
/// position this profile saves is the one it came from, not the place it looked at.
public struct FamilyHold: Equatable, Sendable {
    /// How long the target must play before it is this profile's position.
    public static let playSeconds: Double = 5
    /// How long the player may take to get to the target (a seek, or a new session) before the
    /// hold is given up.
    public static let arriveSeconds: Double = 20

    /// The position before the jump (saved meanwhile).
    public var position: Double
    /// The jump target.
    public var target: Double
    /// When the jump was made, on the caller's monotonic clock (seconds).
    public var since: Double
    /// The player has been seen at the target.
    public private(set) var arrived = false

    public init(position: Double, target: Double, since: Double = 0) {
        self.position = position
        self.target = target
        self.since = since
    }

    /// The position to save when the player is at `now` (file seconds) on `clock` (the same
    /// clock as `since`). Until the player has got to the target the position stays the old one
    /// (a seek takes a moment, and the player still shows where it was); then, for
    /// `playSeconds` there, too. `release` says the hold is over: the real position is saved from now on
    /// (it played on there, the viewer went elsewhere, or the target was never reached).
    public mutating func saved(now: Double, clock: Double) -> (position: Double, release: Bool) {
        if !arrived {
            if abs(now - target) <= 1.5 {
                arrived = true
            } else if clock - since > Self.arriveSeconds {
                return (now, true)
            } else {
                return (position, false)
            }
        }
        if now >= target - 1.5, now < target + Self.playSeconds { return (position, false) }
        return (now, true)
    }
}

extension APIClient {
    /// `GET /api/items/{id}/family`: the other profiles' places in the item, newest first. An older
    /// server, or an item with no family view, answers nothing: an empty list. An entry that does
    /// not decode is left out.
    public func family(itemId: Int) async throws -> [FamilyMember] {
        struct Answer: Decodable {
            var members: [Lenient<FamilyMember>]
            init(from decoder: Decoder) throws {
                members = try decoder.container(keyedBy: CodingKeys.self).value(.members, default: [])
            }

            enum CodingKeys: String, CodingKey { case members }
        }
        do {
            let answer: Answer = try await send(.get, "/api/items/\(itemId)/family")
            return answer.members.compactMap(\.value)
        } catch let error as APIError where [400, 404, 405].contains(error.statusCode ?? 0) {
            return []
        }
    }

    /// `POST /api/progress/{itemId}/adopt`: `userId`'s unfinished position in the item becomes this
    /// profile's own; theirs is never written. 404 when they are not in this profile's family view
    /// or have no unfinished position there.
    public func adoptProgress(itemId: Int, userId: Int) async throws {
        struct Body: Encodable { var userId: Int }
        try await sendWithoutResponse(.post, "/api/progress/\(itemId)/adopt", json: Body(userId: userId))
    }
}
