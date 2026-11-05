import Foundation

/// The rest of a paged list after the items already on screen, fetched one page at a time
/// in the background — e.g. to queue a whole song library after the first page plays.
///
/// A failed page is retried after each of `retryDelays` (transport errors, `429` and
/// `5xx` only); a `401`, another `4xx` or the last failed retry ends the walk with that
/// error. Items already delivered (or loaded before) are skipped, because items added
/// to the library while paging shift later pages.
public struct RemainingPages<Element: Decodable & Identifiable & Sendable>: Sendable where Element.ID: Sendable {
    public typealias Fetch = @Sendable (_ offset: Int, _ limit: Int) async throws -> Page<Element>
    public typealias Sleep = @Sendable (Duration) async throws -> Void

    public let pageSize: Int
    public let retryDelays: [Duration]
    private let loaded: [Element.ID]
    private let total: Int
    private let fetch: Fetch
    private let sleep: Sleep

    /// - Parameters:
    ///   - loaded: what is already shown, from offset 0.
    ///   - total: the list's `total` as last reported.
    public init(
        after loaded: [Element],
        total: Int,
        pageSize: Int = 200,
        retryDelays: [Duration] = [.seconds(1), .seconds(3), .seconds(9)],
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        fetch: @escaping @Sendable (_ offset: Int, _ limit: Int) async throws -> Page<Element>
    ) {
        self.loaded = loaded.map(\.id)
        self.total = total
        self.pageSize = max(1, pageSize)
        self.retryDelays = retryDelays
        self.sleep = sleep
        self.fetch = fetch
    }

    /// Whether anything is left to fetch.
    public var isEmpty: Bool { loaded.count >= total }

    /// Fetches each remaining page and hands its new items to `deliver`, in list order.
    /// Stops when the list ends, when `deliver` returns false or when the task is
    /// cancelled (without an error).
    public func run(deliver: ([Element]) async -> Bool) async throws {
        var seen = Set(loaded)
        var offset = loaded.count
        var total = total
        while offset < total {
            try Task.checkCancellation()
            let page = try await fetchWithRetry(offset: offset)
            if page.items.isEmpty { return }
            offset += page.items.count
            total = page.total
            let fresh = page.items.filter { seen.insert($0.id).inserted }
            if !fresh.isEmpty {
                guard !Task.isCancelled, await deliver(fresh) else { return }
            }
        }
    }

    private func fetchWithRetry(offset: Int) async throws -> Page<Element> {
        var attempt = 0
        while true {
            do {
                return try await fetch(offset, pageSize)
            } catch {
                guard attempt < retryDelays.count, Self.isRetryable(error) else { throw error }
                var delay = retryDelays[attempt]
                if case .server(_, _, _, let retryAfter?) = error as? APIError, retryAfter > 0 {
                    delay = max(delay, .milliseconds(Int(retryAfter * 1000)))
                }
                attempt += 1
                try await sleep(delay)
            }
        }
    }

    /// Transport failures, `429` and `5xx` can pass; other statuses (`401`, `404`...) will not.
    static func isRetryable(_ error: Error) -> Bool {
        if error is CancellationError { return false }
        guard let error = error as? APIError else { return true }
        switch error {
        case .transport: return true
        case .server(let status, _, _, _): return status == 429 || status >= 500
        case .unauthorized, .decoding, .invalidURL: return false
        }
    }
}
