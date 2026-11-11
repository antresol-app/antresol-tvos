import AntresolKit
import Foundation
import Observation
import SwiftUI

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
        /// Offer "Resume from …" or "Start Over" when there is a saved position.
        case ask
    }

    /// What to play: a movie, an episode, or a series (its next episode).
    struct Request: Identifiable, Hashable {
        let id = UUID()
        let card: Card
        let start: StartPoint
        /// The version (file) to play; nil plays the item's first file.
        var fileId: Int?
    }

    /// A live channel to watch: the whole list, and the filter it was opened from (channel
    /// up / down stays inside it).
    struct LiveRequest: Identifiable, Hashable {
        let id = UUID()
        let channel: Channel
        let channels: [Channel]
        let filter: ChannelFilter
    }

    /// The request the player is showing, if any.
    var presented: Request?

    /// The live channel the live player is showing, if any.
    var presentedChannel: LiveRequest?

    /// Incremented each time the player closes; pages observe it to reload progress.
    private(set) var completedSessions = 0

    private var mediaKeys: MediaKeyStore?
    private var mediaKeyToken: String?

    func play(_ card: Card, from start: StartPoint = .resume, fileId: Int? = nil) {
        presented = Request(card: card, start: start, fileId: fileId)
    }

    /// Opens the live player on `channel`; channel up / down moves through the channels of
    /// `filter`, by number.
    func watch(_ channel: Channel, channels: [Channel], filter: ChannelFilter = .all) {
        presentedChannel = LiveRequest(channel: channel, channels: channels, filter: filter)
    }

    /// The live player closed. `completedSessions` is left alone: a channel is not a
    /// playback session, nothing of the library changed (TV is TV).
    func liveChannelDidClose() {
        presentedChannel = nil
        liveSessions += 1
    }

    /// Incremented each time the live player closes, so the TV tab can refresh its list
    /// (favourites and the last channel may have changed there).
    private(set) var liveSessions = 0

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

extension View {
    /// The remote's Play/Pause on a focused movie, show or episode card starts it (with
    /// resume), as in the TV app. Other cards keep the shell's handler (music).
    func playsOnPlayPause(_ card: Card) -> some View {
        modifier(PlayOnPlayPause(card: card))
    }
}

private struct PlayOnPlayPause: ViewModifier {
    let card: Card
    @Environment(PlaybackCoordinator.self) private var playback

    func body(content: Content) -> some View {
        if card.kind.isVideo {
            content.onPlayPauseCommand { playback.play(card, from: .resume) }
        } else {
            content
        }
    }
}
