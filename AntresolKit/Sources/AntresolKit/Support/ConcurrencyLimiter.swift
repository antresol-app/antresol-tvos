import Foundation

/// Lets at most `limit` pieces of work run at once; the rest wait their turn, first come
/// first served. For CPU-bound work started from many places at the same time (artwork
/// decodes while a grid scrolls), so it does not take every thread of the shared pool.
public actor ConcurrencyLimiter {
    public nonisolated let limit: Int
    private var running = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []

    public init(limit: Int) {
        self.limit = max(1, limit)
    }

    /// Runs `work` once a slot is free and gives the slot back when it returns.
    public nonisolated func run<T: Sendable>(_ work: @Sendable () throws -> T) async rethrows -> T {
        await acquire()
        do {
            let result = try work()
            await release()
            return result
        } catch {
            await release()
            throw error
        }
    }

    private func acquire() async {
        if running < limit {
            running += 1
            return
        }
        // The slot is handed over by `release`, so `running` stays as it is.
        await withCheckedContinuation { waiting.append($0) }
    }

    private func release() {
        if waiting.isEmpty {
            running -= 1
        } else {
            waiting.removeFirst().resume()
        }
    }
}
