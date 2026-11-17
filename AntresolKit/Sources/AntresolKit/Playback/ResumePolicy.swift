import Foundation

/// Where to resume playback, following the web app's rules.
public enum ResumePolicy {
    /// Video resume point in seconds: the stored position unless finished.
    public static func videoStartSec(_ progress: PlaybackProgress?) -> Double {
        guard let progress, progress.exists, !progress.finished else { return 0 }
        return Double(progress.positionMs) / 1000
    }
}

/// What Try Again does after a playback error.
public enum PlaybackRetry: Equatable, Sendable {
    /// The item and where it starts are known: a new session at this file position.
    case restart(at: Double)
    /// Nothing is settled for the card yet (its item or its saved position did not
    /// arrive): open it again, which asks for both.
    case reopen

    /// - Parameters:
    ///   - resolvedItemId: the item the player has resolved, if any.
    ///   - cardId: the card being played (or prepared).
    ///   - startResolved: the resolved item's start position is known (a session was
    ///     begun for it). False while its saved position is still being asked for, so a
    ///     failed progress request is asked again and not read as "start at 0", and the
    ///     next episode does not start at the previous one's offset.
    ///   - playerPosition: the player's file position, when it has one.
    ///   - requestedPosition: where the last session was asked to start (or stopped).
    public static func plan(
        resolvedItemId: Int?, cardId: Int, startResolved: Bool, playerPosition: Double?, requestedPosition: Double
    ) -> PlaybackRetry {
        guard let resolvedItemId, resolvedItemId == cardId, startResolved else { return .reopen }
        return .restart(at: playerPosition ?? requestedPosition)
    }
}
