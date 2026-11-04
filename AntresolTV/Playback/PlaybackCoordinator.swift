import AntresolKit
import Foundation
import Observation

/// The single entry point for starting video playback. Views call `play(_:from:)`; the
/// shell presents the player for the pending request and reports when it closes, so
/// pages can refresh their progress.
@MainActor
@Observable
final class PlaybackCoordinator {
    /// Where playback starts.
    enum StartPoint: Hashable {
        /// The saved position, or the beginning when there is none or it was finished.
        case resume
        case beginning
    }

    /// What to play: a movie, an episode, or a series (its next episode).
    struct Request: Identifiable, Hashable {
        let id = UUID()
        let card: Card
        let start: StartPoint
    }

    /// The request the player is showing, if any.
    var presented: Request?

    /// Incremented each time the player closes; pages observe it to reload progress.
    private(set) var completedSessions = 0

    private var mediaKeys: MediaKeyStore?
    private var mediaKeyToken: String?

    func play(_ card: Card, from start: StartPoint = .resume) {
        presented = Request(card: card, start: start)
    }

    func playerDidClose() {
        presented = nil
        completedSessions += 1
    }

    /// The media-key cache for the signed-in profile; a new profile gets a new cache.
    func mediaKeyStore(for client: APIClient) -> MediaKeyStore {
        if let mediaKeys, mediaKeyToken == client.token {
            return mediaKeys
        }
        let store = MediaKeyStore(client: client)
        mediaKeys = store
        mediaKeyToken = client.token
        return store
    }
}
