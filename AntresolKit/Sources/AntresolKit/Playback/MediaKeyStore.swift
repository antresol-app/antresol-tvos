import Foundation

/// Caches the media key (`?mk=`) and refreshes it when less than `refreshMargin`
/// of its 12-hour lifetime is left.
public actor MediaKeyStore {
    private let client: APIClient
    private let refreshMargin: TimeInterval
    private let now: @Sendable () -> Date
    private var cached: MediaKey?
    private var pending: Task<MediaKey, Error>?

    public init(client: APIClient, refreshMargin: TimeInterval = 3600, now: @escaping @Sendable () -> Date = { Date() }) {
        self.client = client
        self.refreshMargin = refreshMargin
        self.now = now
    }

    /// A key valid for at least `refreshMargin`.
    public func key() async throws -> String {
        if let cached, let expiry = cached.expiryDate, expiry.timeIntervalSince(now()) > refreshMargin {
            return cached.key
        }
        if let pending {
            return try await pending.value.key
        }
        let task = Task { [client] in try await client.mediaKey() }
        pending = task
        defer { pending = nil }
        let fresh = try await task.value
        cached = fresh
        return fresh.key
    }

    /// Forgets the cached key, e.g. after switching profiles.
    public func invalidate() {
        cached = nil
    }
}
