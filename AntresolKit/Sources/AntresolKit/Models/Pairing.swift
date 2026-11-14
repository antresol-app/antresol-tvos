import Foundation

/// A TV sign-in code, `ABC234`: 6 characters of `ABCDEFGHJKMNPQRSTUVWXYZ23456789`.
public enum PairingCode {
    public static let alphabet = Set("ABCDEFGHJKMNPQRSTUVWXYZ23456789")
    public static let length = 6

    /// "ABC 234" for display; anything that is not a 6-character code is returned as is.
    public static func display(_ code: String) -> String {
        guard code.count == length else { return code }
        return String(code.prefix(3)) + " " + String(code.suffix(3))
    }

    /// The code as the server keeps it: upper case, spaces and dashes removed. Nil when
    /// what is left is not a valid code.
    public static func normalize(_ input: String) -> String? {
        let code = String(input.uppercased().filter { $0 != " " && $0 != "-" })
        guard code.count == length, code.allSatisfy(alphabet.contains) else { return nil }
        return code
    }
}

/// `POST /api/auth/pair/start`: a code for the TV to show.
public struct PairingTicket: Hashable, Sendable {
    public var code: String
    /// Kept in memory only: never shown, logged or put in a URL.
    public var secret: String
    /// What the QR code encodes, verbatim.
    public var url: String
    /// When the code stops working, on this device's clock (the server's `expiresAt`,
    /// shifted by the difference between the clocks when the server sent its `Date`).
    public var expiresAt: Date
    /// Seconds between polls.
    public var interval: Double
    public var serverId: String

    public init(code: String, secret: String, url: String, expiresAt: Date, interval: Double, serverId: String) {
        self.code = code
        self.secret = secret
        self.url = url
        self.expiresAt = expiresAt
        self.interval = interval
        self.serverId = serverId
    }

    /// "ABC 234".
    public var displayCode: String { PairingCode.display(code) }

    /// `<host>/pair` (or `<host>:<port>/pair`) for "open … and type the code".
    public var pairPage: String {
        guard let components = URLComponents(string: url), let host = components.host else { return url }
        let port = components.port.map { ":\($0)" } ?? ""
        return host + port + components.path
    }
}

/// What `POST /api/auth/pair/poll` said.
public enum PairingPoll: Equatable, Sendable {
    /// Keep polling; the server may move the expiry and the interval.
    case pending(expiresAt: Date?, interval: Double?)
    /// Signed in: the token is a normal device token, handed out once.
    case approved(token: String, user: User)
    /// The phone declined.
    case denied
    /// Expired, already picked up or unknown: start again.
    case expired
}

struct PairingStartRequest: Encodable {
    let device: DeviceInfo
}

struct PairingStartBody: Decodable {
    var code: String
    var secret: String
    var expiresAt: String
    var interval: Double?
    var url: String
    var serverId: String?
}

struct PairingPollRequest: Encodable {
    let secret: String
}

struct PairingPollBody: Decodable {
    var status: String
    var expiresAt: String?
    var interval: Double?
    var token: String?
    var user: User?
}
