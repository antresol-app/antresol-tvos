import Foundation

/// `GET /api/health`.
public struct ServerHealth: Decodable, Hashable, Sendable {
    public var ok: Bool
    /// Stable 32-hex id of the server; key stored credentials with it.
    public var serverId: String
    public var version: String

    enum CodingKeys: String, CodingKey { case ok, serverId, version }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ok = c.value(.ok, default: false)
        serverId = c.value(.serverId, default: "")
        version = c.value(.version, default: "")
    }
}

/// `GET /api/setup`.
public struct SetupStatus: Decodable, Hashable, Sendable {
    public var needsSetup: Bool
    public var remote: Bool

    enum CodingKeys: String, CodingKey { case needsSetup, remote }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        needsSetup = c.value(.needsSetup, default: false)
        remote = c.value(.remote, default: false)
    }
}

/// An entry of the profile picker, `GET /api/profiles`.
public struct Profile: Codable, Hashable, Identifiable, Sendable {
    public var id: Int
    public var name: String
    public var avatar: String
    /// The profile's photo, `/api/profiles/{id}/photo?v=…` (no token needed; the version
    /// changes with each upload, so a new photo is a new address), or "" for the letter.
    public var photo: String
    public var hasPassword: Bool

    public init(id: Int, name: String, avatar: String, photo: String = "", hasPassword: Bool) {
        self.id = id
        self.name = name
        self.avatar = avatar
        self.photo = photo
        self.hasPassword = hasPassword
    }

    enum CodingKeys: String, CodingKey { case id, name, avatar, photo, hasPassword }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        name = c.value(.name, default: "")
        avatar = c.value(.avatar, default: AvatarPreset.fallback.rawValue)
        photo = c.value(.photo, default: "")
        hasPassword = c.value(.hasPassword, default: false)
    }

    public var avatarPreset: AvatarPreset {
        AvatarPreset(value: avatar)
    }
}

/// The signed-in user (`GET /api/me`, `user` of the token response, admin user lists).
public struct User: Codable, Hashable, Identifiable, Sendable {
    public var id: Int
    public var name: String
    public var avatar: String
    /// As `Profile.photo`.
    public var photo: String
    public var hasPassword: Bool
    public var isAdmin: Bool
    public var isKid: Bool
    /// Highest age rating a kid profile may see, e.g. "6+".
    public var maxRating: String?
    /// The request came from outside the home network.
    public var remote: Bool
    public var libraryOnly: Bool
    /// The separate history this device writes into («Отдельная история на этом
    /// устройстве»), nil for the profile's own. The person stays the one signed in; only
    /// progress, watched marks, Continue Watching and the family view go to the history.
    public var deviceHistory: HistoryRef?

    public init(
        id: Int, name: String, avatar: String, photo: String = "", hasPassword: Bool = false, isAdmin: Bool = false,
        isKid: Bool = false, maxRating: String? = nil, remote: Bool = false, libraryOnly: Bool = true,
        deviceHistory: HistoryRef? = nil
    ) {
        self.id = id
        self.name = name
        self.avatar = avatar
        self.photo = photo
        self.hasPassword = hasPassword
        self.isAdmin = isAdmin
        self.isKid = isKid
        self.maxRating = maxRating
        self.remote = remote
        self.libraryOnly = libraryOnly
        self.deviceHistory = deviceHistory
    }

    enum CodingKeys: String, CodingKey {
        case id, name, avatar, photo, hasPassword, isAdmin, isKid, maxRating, remote, libraryOnly, deviceHistory
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        name = c.value(.name, default: "")
        avatar = c.value(.avatar, default: AvatarPreset.fallback.rawValue)
        photo = c.value(.photo, default: "")
        hasPassword = c.value(.hasPassword, default: false)
        isAdmin = c.value(.isAdmin, default: false)
        isKid = c.value(.isKid, default: false)
        maxRating = c.optional(.maxRating)
        remote = c.value(.remote, default: false)
        libraryOnly = c.value(.libraryOnly, default: true)
        deviceHistory = c.optional(.deviceHistory)
    }

    public var avatarPreset: AvatarPreset {
        AvatarPreset(value: avatar)
    }
}

/// The device registered with a token (`device` in `POST /api/auth/token`).
public struct DeviceInfo: Codable, Hashable, Sendable {
    /// Stable per installation; must match `^[A-Za-z0-9-]{8,64}$`.
    public var id: String
    public var name: String
    public var model: String
    public var version: String

    public init(id: String, name: String, model: String, version: String) {
        self.id = id
        self.name = name
        self.model = model
        self.version = version
    }

    /// Whether `id` is accepted by the server.
    public static func isValidID(_ id: String) -> Bool {
        (8...64).contains(id.count) && id.allSatisfy { char in
            char == "-" || (char.isASCII && (char.isLetter || char.isNumber))
        }
    }
}

/// Body of `POST /api/auth/token`.
public struct TokenRequest: Encodable, Sendable {
    public var userId: Int
    public var password: String?
    public var device: DeviceInfo

    public init(userId: Int, password: String?, device: DeviceInfo) {
        self.userId = userId
        self.password = password
        self.device = device
    }
}

/// Response of `POST /api/auth/token`.
public struct TokenResponse: Decodable, Sendable {
    public var token: String
    public var user: User
}

/// Response of `POST /api/auth/media-key`.
public struct MediaKey: Decodable, Hashable, Sendable {
    /// Append as `?mk=` to stream, HLS, audio and track URLs.
    public var key: String
    public var expiresAt: String

    public init(key: String, expiresAt: String) {
        self.key = key
        self.expiresAt = expiresAt
    }

    public var expiryDate: Date? {
        Timestamp.parse(expiresAt)
    }
}

/// A native device session of the current user, `GET /api/me/devices`.
public struct DeviceSession: Decodable, Hashable, Identifiable, Sendable {
    /// Session row id (not `DeviceInfo.id`).
    public var id: Int
    public var name: String
    public var model: String
    public var version: String
    public var createdAt: String
    public var lastSeen: String
    public var current: Bool
    /// Its separate history (nil: the profile's own).
    public var history: HistoryRef?

    enum CodingKeys: String, CodingKey { case id, name, model, version, createdAt, lastSeen, current, history }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        name = c.value(.name, default: "")
        model = c.value(.model, default: "")
        version = c.value(.version, default: "")
        createdAt = c.value(.createdAt, default: "")
        lastSeen = c.value(.lastSeen, default: "")
        current = c.value(.current, default: false)
        history = c.optional(.history)
    }
}

extension DeviceSession {
    public var lastSeenDate: Date? { Timestamp.parse(lastSeen) }

    /// A devices list for display: the current device first, then the most recently seen
    /// (devices without a readable time last, newest session first among them).
    public static func displayOrder(_ devices: [DeviceSession]) -> [DeviceSession] {
        devices.sorted { a, b in
            if a.current != b.current { return a.current }
            switch (a.lastSeenDate, b.lastSeenDate) {
            case let (x?, y?) where x != y: return x > y
            case (_?, nil): return true
            case (nil, _?): return false
            default: return a.id > b.id
            }
        }
    }
}

struct ItemsEnvelope<Element: Decodable & Sendable>: Decodable, Sendable {
    var items: [Element]

    enum CodingKeys: String, CodingKey { case items }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        items = c.value(.items, default: [])
    }
}

/// The error body every failed request carries: `{"error": "...", "code"?: "..."}`.
public struct ErrorBody: Decodable, Hashable, Sendable {
    public var error: String
    public var code: String?
}

/// `GET /api/library/status` (admin).
public struct LibraryStatus: Decodable, Hashable, Sendable {
    public var running: Bool
    public var queued: Bool
    public var startedAt: String?
    public var finishedAt: String?
    public var error: String?
    public var movies: Int
    public var episodes: Int
    public var albums: Int
    public var tracks: Int
    public var books: Int
    public var audiobooks: Int
    public var comics: Int
    public var files: Int
    public var skipped: Int
    public var removed: Int

    enum CodingKeys: String, CodingKey {
        case running, queued, startedAt, finishedAt, error, movies, episodes, albums, tracks
        case books, audiobooks, comics, files, skipped, removed
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        running = c.value(.running, default: false)
        queued = c.value(.queued, default: false)
        startedAt = c.optional(.startedAt)
        finishedAt = c.optional(.finishedAt)
        error = c.optional(.error)
        movies = c.value(.movies, default: 0)
        episodes = c.value(.episodes, default: 0)
        albums = c.value(.albums, default: 0)
        tracks = c.value(.tracks, default: 0)
        books = c.value(.books, default: 0)
        audiobooks = c.value(.audiobooks, default: 0)
        comics = c.value(.comics, default: 0)
        files = c.value(.files, default: 0)
        skipped = c.value(.skipped, default: 0)
        removed = c.value(.removed, default: 0)
    }
}

/// A device's separate history: the managed account it writes into.
public struct HistoryRef: Codable, Hashable, Sendable {
    public var id: Int
    public var name: String

    public init(id: Int, name: String) {
        self.id = id
        self.name = name
    }

    enum CodingKeys: String, CodingKey { case id, name }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        name = c.value(.name, default: "")
    }
}

/// One of the person's separate histories, `GET /api/me/managed`.
public struct ManagedAccount: Decodable, Hashable, Identifiable, Sendable {
    public var id: Int
    public var name: String
    public var avatar: String
    /// How many devices write into it now.
    public var deviceCount: Int

    public init(id: Int, name: String, avatar: String = "", deviceCount: Int = 0) {
        self.id = id
        self.name = name
        self.avatar = avatar
        self.deviceCount = deviceCount
    }

    enum CodingKeys: String, CodingKey { case id, name, avatar, devices }

    private struct Device: Decodable {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        name = c.value(.name, default: "")
        avatar = c.value(.avatar, default: "")
        deviceCount = (c.optional(.devices) as [Device]?)?.count ?? 0
    }
}

/// What `PUT /api/me/devices/current/history` changes: on into an account (nil: the one
/// the device had, else a new one named after it), or off, moving what was watched here
/// into the profile (`merge`) or keeping it apart.
public enum DeviceHistoryChange: Hashable, Sendable {
    case on(accountId: Int?)
    case off(merge: Bool)
}
