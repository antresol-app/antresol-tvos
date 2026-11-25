import Foundation

/// Errors thrown by `APIClient`.
public enum APIError: Error, Hashable, Sendable {
    /// `401`: the token is missing, invalid or revoked, or the password was wrong.
    case unauthorized(message: String?)
    /// Any other non-2xx response with the server's (localized) message.
    case server(status: Int, message: String?, code: String?, retryAfter: Double?)
    /// The response body did not match the expected shape.
    case decoding(String)
    /// The request could not be sent or no response arrived. `hostUnreachable`: the host's name does
    /// not resolve, or the device has no network (`isHostUnreachable`).
    case transport(String, hostUnreachable: Bool = false)
    /// The URL could not be built from the server address and path.
    case invalidURL(String)

    public var statusCode: Int? {
        switch self {
        case .unauthorized: return 401
        case .server(let status, _, _, _): return status
        default: return nil
        }
    }

    /// Server-provided, localized message when there is one.
    public var serverMessage: String? {
        switch self {
        case .unauthorized(let message): return message
        case .server(_, let message, _, _): return message
        default: return nil
        }
    }

    /// Machine-readable error code, e.g. `remote-passwordless`.
    public var code: String? {
        if case .server(_, _, let code, _) = self { return code }
        return nil
    }

    public var isNotFound: Bool { statusCode == 404 }

    /// The failed request shows the host cannot be reached at all: its name does not resolve, or the
    /// device has no network. Another scheme or port of the same host fails the same way, so nothing
    /// is gained by trying it. (A refused or timed-out connection says nothing of the other port.)
    public var isHostUnreachable: Bool {
        if case .transport(_, let unreachable) = self { return unreachable }
        return false
    }

    /// Whether `error` is one of the `URLError`s that make a host unreachable.
    static func isHostUnreachable(_ error: URLError) -> Bool {
        [.cannotFindHost, .dnsLookupFailed, .notConnectedToInternet].contains(error.code)
    }

    /// `429`: the profile already has the maximum number of HLS sessions.
    public var isTooManySessions: Bool { statusCode == 429 }
}

extension APIError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unauthorized(let message):
            return message ?? "Sign in required"
        case .server(let status, let message, _, _):
            return message ?? "Server error \(status)"
        case .decoding(let detail):
            return "Unexpected server response: \(detail)"
        case .transport(let detail, _):
            return detail
        case .invalidURL(let detail):
            return "Invalid address: \(detail)"
        }
    }
}
