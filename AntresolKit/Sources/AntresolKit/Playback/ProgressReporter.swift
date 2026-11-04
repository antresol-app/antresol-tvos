import Foundation

/// Reports playback position with `PUT /api/progress/{itemId}` the way the web player
/// does (§11): periodically while playing when the position moved enough, and on
/// demand (pause, backgrounding, exit) via `flush()`.
public actor ProgressReporter {
    public let itemId: Int
    private let client: APIClient
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
        self.client = client
        self.itemId = itemId
        self.interval = interval
        self.minimumChangeMs = minimumChangeMs
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
                guard !Task.isCancelled else { return }
                await self?.reportIfMoved()
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
        await send(latest)
    }

    /// Forced write of the latest position if it differs from the last one sent.
    public func flush() async {
        guard let latest, latest.positionMs != lastSentPositionMs else { return }
        await send(latest)
    }

    private func send(_ value: (positionMs: Int, durationMs: Int)) async {
        do {
            try await client.updateProgress(itemId: itemId, .media(positionMs: value.positionMs, durationMs: value.durationMs))
            lastSentPositionMs = value.positionMs
        } catch {
            // Keep the value; the next tick or flush retries.
        }
    }
}
