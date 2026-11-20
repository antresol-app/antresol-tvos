import Foundation

/// Reports playback position with `PUT /api/progress/{itemId}` the way the web player
/// does (§11): periodically while playing when the position moved enough, and on
/// demand (pause, backgrounding, exit) via `flush()`.
public actor PlaybackProgressReporter {
    /// Where a position goes: milliseconds played, the duration, and whether the write must not be
    /// held back (a pause, the end, the player closing).
    public typealias Sender = @Sendable (_ positionMs: Int, _ durationMs: Int, _ keepalive: Bool) async throws -> Void

    public let itemId: Int
    private let send: Sender
    private let interval: TimeInterval
    private let minimumChangeMs: Int
    private var latest: (positionMs: Int, durationMs: Int)?
    private var lastSentPositionMs: Int?
    private var timer: Task<Void, Never>?

    /// - Parameters:
    ///   - interval: seconds between periodic writes (10 s for video and audiobooks).
    ///   - minimumChangeMs: periodic writes are skipped below this movement
    ///     (500 ms for video, 1000 ms for audiobooks).
    public init(client: APIClient, itemId: Int, interval: TimeInterval = 10, minimumChangeMs: Int = 500) {
        self.itemId = itemId
        self.send = { positionMs, durationMs, _ in
            try await client.updateProgress(itemId: itemId, .media(positionMs: positionMs, durationMs: durationMs))
        }
        self.interval = interval
        self.minimumChangeMs = minimumChangeMs
    }

    /// A reporter whose writes go to `send`: an addon's stream, whose position is not a library
    /// item's. `itemId` is 0.
    public init(interval: TimeInterval = 10, minimumChangeMs: Int = 500, send: @escaping Sender) {
        self.itemId = 0
        self.send = send
        self.interval = interval
        self.minimumChangeMs = minimumChangeMs
    }

    deinit {
        timer?.cancel()
    }

    /// Records the current position (file or whole-book milliseconds).
    public func update(positionMs: Int, durationMs: Int) {
        latest = (max(0, positionMs), max(0, durationMs))
    }

    /// Starts periodic reporting.
    public func start() {
        guard timer == nil else { return }
        let nanos = UInt64(interval * 1_000_000_000)
        timer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: nanos)
                guard !Task.isCancelled, let self else { return }
                await self.reportIfMoved()
            }
        }
    }

    /// Stops periodic reporting and writes the final position.
    public func stop() async {
        timer?.cancel()
        timer = nil
        await flush()
    }

    /// Periodic write: only when the position moved at least `minimumChangeMs`.
    public func reportIfMoved() async {
        guard let latest else { return }
        if let last = lastSentPositionMs, abs(latest.positionMs - last) < minimumChangeMs { return }
        await deliver(latest, keepalive: false)
    }

    /// Forced write of the latest position if it differs from the last one sent.
    public func flush() async {
        guard let latest, latest.positionMs != lastSentPositionMs else { return }
        await deliver(latest, keepalive: true)
    }

    private func deliver(_ value: (positionMs: Int, durationMs: Int), keepalive: Bool) async {
        do {
            try await send(value.positionMs, value.durationMs, keepalive)
            lastSentPositionMs = value.positionMs
        } catch {
            // Keep the value; the next tick or flush retries.
        }
    }
}
