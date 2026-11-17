import Foundation

/// One request at a time for something that can be started over (the guide's pages):
/// a request begun before the last `reset` is stale, its answer is not used and it no
/// longer blocks the next one.
public struct RequestGate: Hashable, Sendable {
    private var epoch = 0
    /// A request of the current epoch is in flight.
    public private(set) var isBusy = false

    public init() {}

    /// A ticket for a new request, nil while one is in flight.
    public mutating func begin() -> Int? {
        guard !isBusy else { return nil }
        isBusy = true
        return epoch
    }

    /// The request with `ticket` came back; whether its answer may be used (false after
    /// a `reset`: it belongs to what was thrown away).
    public mutating func finish(_ ticket: Int) -> Bool {
        guard ticket == epoch else { return false }
        isBusy = false
        return true
    }

    /// Starts over: requests in flight become stale, and a new one may begin at once.
    public mutating func reset() {
        epoch += 1
        isBusy = false
    }
}
