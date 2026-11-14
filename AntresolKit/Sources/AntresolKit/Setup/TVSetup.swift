import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking // URLError on Linux
#endif

// TV setup by phone: the TV's first screen shows a QR code of a tiny HTTP endpoint on
// the TV itself (`http://<tv-lan-ip>:<port>/setup?n=<nonce>&v=1`). A phone posts the
// server address there (the Antresol app as JSON, or the phone's browser through a
// form), the TV checks and saves that server, starts QR sign-in on it and answers with
// the sign-in code, which the phone app then approves on its own server.
//
// Everything here is plain Foundation; the listener that serves it is in
// `TVSetupListener.swift` (Network framework).

/// The setup URL the TV's QR code encodes.
public enum TVSetupLink {
    /// Protocol version in the `v` query parameter.
    public static let version = 1
    public static let path = "/setup"

    /// `http://<host>:<port>/setup?n=<nonce>&v=1`.
    public static func url(host: String, port: UInt16, nonce: String) -> String {
        let shownHost = host.contains(":") ? "[\(host)]" : host
        return "http://\(shownHost):\(port)\(path)?n=\(nonce)&v=\(version)"
    }
}

/// The setup screen's one-time key `n`: 128 random bits, base64url without padding.
/// New each time the screen opens; good for one successful setup and at most
/// `lifetime` seconds.
public struct TVSetupNonce: Sendable, Equatable {
    public static let lifetime: TimeInterval = 10 * 60

    public let value: String
    public let issuedAt: Date

    public init(value: String, issuedAt: Date) {
        self.value = value
        self.issuedAt = issuedAt
    }

    /// A fresh random nonce.
    public static func make(now: Date = Date()) -> TVSetupNonce {
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<16).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        return TVSetupNonce(value: base64URL(Data(bytes)), issuedAt: now)
    }

    public var expiresAt: Date { issuedAt.addingTimeInterval(Self.lifetime) }

    public func isExpired(at now: Date) -> Bool { now >= expiresAt }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// Only clients on the home network may set the TV up: private IPv4 (10/8, 172.16/12,
/// 192.168/16), link-local (169.254/16, fe80::/10), unique-local IPv6 (fc00::/7) and
/// loopback. IPv4-mapped IPv6 (`::ffff:192.168.1.5`) counts as its IPv4.
public enum LocalAddress {
    public static func isPrivate(_ address: String) -> Bool {
        var text = address.trimmingCharacters(in: .whitespaces).lowercased()
        if text.hasPrefix("[") && text.hasSuffix("]") { text = String(text.dropFirst().dropLast()) }
        if let zone = text.firstIndex(of: "%") { text = String(text[..<zone]) }
        if text.hasPrefix("::ffff:"), let v4 = ipv4(String(text.dropFirst(7))) {
            return isPrivate(v4)
        }
        if let v4 = ipv4(text) { return isPrivate(v4) }
        guard text.contains(":") else { return false }
        if text == "::1" { return true }
        let first = text.split(separator: ":", omittingEmptySubsequences: false).first.map(String.init) ?? ""
        guard !first.isEmpty, first.count <= 4, let head = UInt16(first, radix: 16) else { return false }
        if head & 0xFE00 == 0xFC00 { return true } // fc00::/7
        if head & 0xFFC0 == 0xFE80 { return true } // fe80::/10
        return false
    }

    /// Whether `address` is a private or link-local IPv4 (what a TV's LAN address is).
    public static func isPrivateIPv4(_ address: String) -> Bool {
        guard let v4 = ipv4(address) else { return false }
        return isPrivate(v4) && v4[0] != 127
    }

    private static func isPrivate(_ o: [UInt8]) -> Bool {
        switch (o[0], o[1]) {
        case (10, _), (127, _): return true
        case (172, 16...31): return true
        case (192, 168): return true
        case (169, 254): return true
        default: return false
        }
    }

    static func ipv4(_ text: String) -> [UInt8]? {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var octets: [UInt8] = []
        for part in parts {
            guard !part.isEmpty, part.count <= 3, part.allSatisfy(\.isASCII), let value = UInt8(part) else { return nil }
            octets.append(value)
        }
        return octets
    }
}

/// At most `limit` requests in any `window` seconds (all clients together).
public struct TVSetupRateLimiter: Sendable {
    public let limit: Int
    public let window: TimeInterval
    private var stamps: [Date] = []

    public init(limit: Int = 10, window: TimeInterval = 60) {
        self.limit = limit
        self.window = window
    }

    /// Counts a request at `now`; false when it is over the limit (not counted then).
    public mutating func allow(at now: Date) -> Bool {
        stamps.removeAll { now.timeIntervalSince($0) >= window }
        guard stamps.count < limit else { return false }
        stamps.append(now)
        return true
    }

    /// Seconds until the next request would be allowed.
    public func retryAfter(at now: Date) -> Int {
        guard let oldest = stamps.first else { return 0 }
        return max(1, Int((window - now.timeIntervalSince(oldest)).rounded(.up)))
    }
}

/// What the phone asked: the server to use (as typed or as the app uses it) and, from
/// the app, the server id it must have.
public struct TVSetupSubmission: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// The Antresol app: JSON in, JSON out.
        case json
        /// The phone's browser (the setup page's form): HTML or a redirect out.
        case form
    }

    public var nonce: String
    public var server: String
    public var serverId: String?
    public var kind: Kind

    public init(nonce: String, server: String, serverId: String?, kind: Kind) {
        self.nonce = nonce
        self.server = server
        self.serverId = serverId
        self.kind = kind
    }

    /// Reads a `POST /setup` body: `application/json` `{"n","server","serverId"?}` or an
    /// `application/x-www-form-urlencoded` form with `n` and `server`. Nil when it is
    /// neither or a field is missing.
    public static func parse(contentType: String?, body: Data) -> TVSetupSubmission? {
        let type = (contentType ?? "").split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
        switch type {
        case "application/json":
            guard let json = try? JSONDecoder().decode(Body.self, from: body),
                  let n = json.n, !n.isEmpty, let server = json.server?.trimmingCharacters(in: .whitespacesAndNewlines), !server.isEmpty
            else { return nil }
            let id = json.serverId?.trimmingCharacters(in: .whitespaces).lowercased()
            return TVSetupSubmission(nonce: n, server: server, serverId: id?.isEmpty == false ? id : nil, kind: .json)
        case "application/x-www-form-urlencoded":
            guard let text = String(data: body, encoding: .utf8) else { return nil }
            let fields = formFields(text)
            guard let n = fields["n"], !n.isEmpty,
                  let server = fields["server"]?.trimmingCharacters(in: .whitespacesAndNewlines), !server.isEmpty
            else { return nil }
            let id = fields["serverId"]?.trimmingCharacters(in: .whitespaces).lowercased()
            return TVSetupSubmission(nonce: n, server: server, serverId: id?.isEmpty == false ? id : nil, kind: .form)
        default:
            return nil
        }
    }

    /// `a=1&b=x+y%2F` → ["a": "1", "b": "x y/"]; the first of repeated names wins.
    static func formFields(_ text: String) -> [String: String] {
        var fields: [String: String] = [:]
        for pair in text.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            func decode(_ s: Substring) -> String? {
                String(s).replacingOccurrences(of: "+", with: " ").removingPercentEncoding
            }
            guard let name = decode(parts[0]), !name.isEmpty, fields[name] == nil else { continue }
            fields[name] = parts.count > 1 ? (decode(parts[1]) ?? "") : ""
        }
        return fields
    }

    private struct Body: Decodable {
        var n: String?
        var server: String?
        var serverId: String?
    }
}

/// `200` of a JSON `POST /setup`: the TV is showing sign-in code `code` of server
/// `sid`; the phone approves it on its own server.
public struct TVSetupAnswer: Codable, Equatable, Sendable {
    public var code: String
    public var sid: String
    /// The server address the TV saved (normalised).
    public var server: String
    /// The TV's name as the server's device list will show it.
    public var device: String

    public init(code: String, sid: String, server: String, device: String) {
        self.code = code
        self.sid = sid
        self.server = server
        self.device = device
    }
}

/// Why a setup request failed: the HTTP status and the `error` code of the JSON body.
public enum TVSetupFailure: Error, Equatable, Sendable {
    /// 400: not a setup request, or the address is not one.
    case badRequest
    /// 404: wrong, used or expired `n`.
    case expiredNonce
    /// 422: the address answers, but not as an Antresol server.
    case notAntresol
    /// 422 (`not_antresol`): an Antresol server that has not been set up yet (no profiles).
    case notSetUp
    /// 422 (`not_antresol`): an Antresol server too old for QR sign-in (saved; the TV shows
    /// its profile picker).
    case pairingUnsupported
    /// 502: the TV cannot reach the address.
    case unreachable
    /// 409: the server's id is not the `serverId` the phone sent.
    case serverMismatch
    /// 429: too many requests (or another setup is in progress).
    case rateLimited(retryAfter: Int)

    public var status: Int {
        switch self {
        case .badRequest: return 400
        case .expiredNonce: return 404
        case .notAntresol, .notSetUp, .pairingUnsupported: return 422
        case .unreachable: return 502
        case .serverMismatch: return 409
        case .rateLimited: return 429
        }
    }

    /// The `error` value of the JSON body (the whole body: clients word it themselves).
    /// The 422s share `not_antresol`, as on Android TV.
    public var code: String {
        switch self {
        case .badRequest: return "bad_request"
        case .expiredNonce: return "expired_nonce"
        case .notAntresol, .notSetUp, .pairingUnsupported: return "not_antresol"
        case .unreachable: return "unreachable"
        case .serverMismatch: return "server_mismatch"
        case .rateLimited: return "rate_limited"
        }
    }

    /// What checking the server address with `/api/health` failing means.
    public static func classify(_ error: Error) -> TVSetupFailure {
        if let failure = error as? TVSetupFailure { return failure }
        switch error as? APIError {
        case .invalidURL?: return .badRequest
        case .transport?: return .unreachable
        case .decoding?, .server?, .unauthorized?: return .notAntresol
        case nil: return error is URLError ? .unreachable : .notAntresol
        }
    }

    /// A one-line explanation for the setup page.
    public func message(russian: Bool) -> String {
        switch self {
        case .badRequest:
            return russian ? "Это не похоже на адрес сервера." : "That doesn't look like a server address."
        case .expiredNonce:
            return russian ? "Код устарел — откройте настройку на телевизоре заново." : "This code has expired. Open the setup on the TV again."
        case .notAntresol:
            return russian ? "По этому адресу отвечает не сервер Antresol." : "This address doesn't answer like an Antresol server."
        case .notSetUp:
            return russian ? "Сервер ещё не настроен. Откройте его в браузере и создайте профиль администратора." : "The server isn't set up yet. Open it in a browser and create the administrator profile."
        case .pairingUnsupported:
            return russian ? "Этот сервер не поддерживает вход с телефона. Обновите его или войдите пультом на телевизоре." : "This server can't sign in with a phone. Update it, or sign in with the remote on the TV."
        case .unreachable:
            return russian ? "Телевизор не может связаться с сервером. Проверьте адрес и что сервер работает." : "The TV can't reach the server. Check the address and that the server is running."
        case .serverMismatch:
            return russian ? "По этому адресу другой сервер." : "A different server answers at this address."
        case .rateLimited:
            return russian ? "Слишком много попыток. Подождите минуту." : "Too many attempts. Wait a minute."
        }
    }
}
