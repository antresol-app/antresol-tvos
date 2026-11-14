import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// TV sign-in by QR code: the TV's half (start, poll). No auth on either.
extension APIClient {
    /// `POST /api/auth/pair/start`: a new code for `device` (a new start with the same
    /// device id cancels the previous code). `now` is this device's clock; the expiry is
    /// moved onto it using the response's `Date` header when there is one.
    public func pairStart(device: DeviceInfo, now: Date = Date()) async throws -> PairingTicket {
        let request = try makeRequest(.post, "/api/auth/pair/start", body: try APIClient.encoder.encode(PairingStartRequest(device: device)))
        let (data, response) = try await perform(request)
        let body: PairingStartBody
        do {
            body = try APIClient.decoder.decode(PairingStartBody.self, from: data)
        } catch {
            throw APIError.decoding("POST /api/auth/pair/start: \(error)")
        }
        guard let serverExpiry = Timestamp.parse(body.expiresAt), !body.secret.isEmpty, !body.url.isEmpty else {
            throw APIError.decoding("POST /api/auth/pair/start: missing code fields")
        }
        let serverNow = response.value(forHTTPHeaderField: "Date").flatMap(APIClient.httpDate)
        return PairingTicket(
            code: body.code,
            secret: body.secret,
            url: body.url,
            expiresAt: APIClient.localTime(serverExpiry, serverNow: serverNow, now: now),
            interval: max(1, body.interval ?? 2),
            serverId: body.serverId ?? ""
        )
    }

    /// `POST /api/auth/pair/poll`. `410` is an answer (denied or expired), not an error;
    /// `429` throws `APIError.server` with `retryAfter`.
    public func pairPoll(secret: String, now: Date = Date()) async throws -> PairingPoll {
        let request = try makeRequest(.post, "/api/auth/pair/poll", body: try APIClient.encoder.encode(PairingPollRequest(secret: secret)))
        let (data, response) = try await perform(request, accepting: [410])
        let body: PairingPollBody
        do {
            body = try APIClient.decoder.decode(PairingPollBody.self, from: data)
        } catch {
            if response.statusCode == 410 { return .expired }
            throw APIError.decoding("POST /api/auth/pair/poll: \(error)")
        }
        switch body.status {
        case "approved":
            guard let token = body.token, !token.isEmpty, let user = body.user else {
                throw APIError.decoding("POST /api/auth/pair/poll: approved without a token")
            }
            return .approved(token: token, user: user)
        case "denied":
            return .denied
        case "pending" where response.statusCode == 200:
            let serverNow = response.value(forHTTPHeaderField: "Date").flatMap(APIClient.httpDate)
            let expiry = body.expiresAt.flatMap(Timestamp.parse).map { APIClient.localTime($0, serverNow: serverNow, now: now) }
            return .pending(expiresAt: expiry, interval: body.interval)
        default:
            return .expired
        }
    }

    /// A server time on this device's clock: `serverTime` moved by how far the server's
    /// clock (its `Date` header) is from `now`. Without a `Date` header, unchanged.
    static func localTime(_ serverTime: Date, serverNow: Date?, now: Date) -> Date {
        guard let serverNow else { return serverTime }
        return now.addingTimeInterval(serverTime.timeIntervalSince(serverNow))
    }

    /// RFC 1123 (`Sun, 14 Nov 2026 12:00:00 GMT`), the HTTP `Date` header.
    static func httpDate(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: text)
    }
}
