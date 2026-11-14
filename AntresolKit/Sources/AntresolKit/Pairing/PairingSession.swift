import Foundation

/// Where TV sign-in by QR code stands.
public enum PairingState: Equatable, Sendable {
    /// Asking the server for a code.
    case starting
    /// Showing `ticket` and polling.
    case waiting(PairingTicket)
    /// A phone approved: sign in with `token` as `user`. Terminal.
    case approved(token: String, user: User)
    /// A phone declined. Terminal: run again for a new code.
    case denied
    /// The server has no QR sign-in (older than the feature). Terminal.
    case unsupported
    /// The server could not be reached or refused; the session retries by itself after
    /// `retryIn` seconds.
    case failed(message: String, retryIn: Double)

    public var isTerminal: Bool {
        switch self {
        case .approved, .denied, .unsupported: return true
        default: return false
        }
    }
}

/// The calls the session makes; `APIClient` is the real one.
public protocol PairingAPI: Sendable {
    func pairStart(device: DeviceInfo, now: Date) async throws -> PairingTicket
    func pairPoll(secret: String, now: Date) async throws -> PairingPoll
}

extension APIClient: PairingAPI {}

/// The TV's side of QR sign-in: starts a code, polls every `interval` seconds, starts a
/// new code when one expires, and stops on approval or denial. One `run` at a time (the
/// token is handed out once; two pollers would race for it). Cancel the task to stop.
public struct PairingSession: Sendable {
    public typealias Sleep = @Sendable (Double) async throws -> Void

    let api: PairingAPI
    let device: DeviceInfo
    let now: @Sendable () -> Date
    let sleep: Sleep
    /// What a failure says (the app's localized text for an error).
    let describe: @Sendable (Error) -> String

    /// Seconds before trying again after a failure without `Retry-After`.
    public static let retryDelay: Double = 5
    /// `Retry-After` default for a 429 without one (the contract's value).
    public static let rateLimitDelay: Double = 30

    public init(
        api: PairingAPI,
        device: DeviceInfo,
        now: @escaping @Sendable () -> Date = { Date() },
        sleep: @escaping Sleep = { seconds in try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000)) },
        describe: @escaping @Sendable (Error) -> String = { $0.localizedDescription }
    ) {
        self.api = api
        self.device = device
        self.now = now
        self.sleep = sleep
        self.describe = describe
    }

    /// Runs until a terminal state (returned) or cancellation (throws `CancellationError`).
    /// `update` gets every state as it happens. `initial` is a code already started (TV
    /// setup by phone starts one before this screen shows): it is polled first instead of
    /// starting another, which would cancel it.
    @discardableResult
    public func run(initial: PairingTicket? = nil, update: @escaping @Sendable (PairingState) async -> Void) async throws -> PairingState {
        var pending = initial.flatMap { now() < $0.expiresAt ? $0 : nil }
        if pending == nil { await update(.starting) }
        while true {
            try Task.checkCancellation()
            let ticket: PairingTicket
            if let started = pending {
                pending = nil
                ticket = started
            } else {
                do {
                    ticket = try await api.pairStart(device: device, now: now())
                } catch let error as APIError where error.statusCode == 404 || error.statusCode == 405 {
                    await update(.unsupported)
                    return .unsupported
                } catch {
                    try Task.checkCancellation()
                    if error is CancellationError { throw error }
                    let wait = Self.delay(after: error)
                    await update(.failed(message: describe(error), retryIn: wait))
                    try await sleep(wait)
                    continue
                }
            }
            await update(.waiting(ticket))
            if let done = try await poll(ticket, update: update) {
                return done
            }
            // expired: a new code right away
        }
    }

    /// Polls one ticket. Returns a terminal state, or nil when the code expired.
    private func poll(_ start: PairingTicket, update: @escaping @Sendable (PairingState) async -> Void) async throws -> PairingState? {
        var ticket = start
        var wait = ticket.interval
        while true {
            try await sleep(wait)
            try Task.checkCancellation()
            wait = ticket.interval
            let answer: PairingPoll
            do {
                answer = try await api.pairPoll(secret: ticket.secret, now: now())
            } catch let error as APIError where error.statusCode == 429 {
                wait = Self.delay(after: error)
                continue
            } catch {
                try Task.checkCancellation()
                if error is CancellationError { throw error }
                // a network error: keep polling while the code lives
                if now() >= ticket.expiresAt { return nil }
                continue
            }
            switch answer {
            case .approved(let token, let user):
                let state = PairingState.approved(token: token, user: user)
                await update(state)
                return state
            case .denied:
                await update(.denied)
                return .denied
            case .expired:
                return nil
            case .pending(let expiresAt, let interval):
                var changed = ticket
                if let expiresAt { changed.expiresAt = expiresAt }
                if let interval, interval >= 1 { changed.interval = interval }
                if changed != ticket {
                    ticket = changed
                    await update(.waiting(ticket))
                }
                wait = ticket.interval
                if now() >= ticket.expiresAt { return nil }
            }
        }
    }

    /// `Retry-After` of a 429, else the plain retry delay.
    static func delay(after error: Error) -> Double {
        if case .server(429, _, _, let retryAfter)? = error as? APIError {
            return max(1, retryAfter ?? rateLimitDelay)
        }
        return retryDelay
    }
}
