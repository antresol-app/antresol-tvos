import Foundation
import Observation

/// A message shown for a few seconds: the shell's banner, the music player's notices and
/// playlist confirmations. A new message starts the time again.
@MainActor
@Observable
final class TimedNotice {
    private(set) var message: String?
    @ObservationIgnored private var task: Task<Void, Never>?

    func show(_ message: String) {
        task?.cancel()
        self.message = message
        task = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.message = nil
        }
    }

    /// Takes the message down now.
    func clear() {
        task?.cancel()
        message = nil
    }
}
