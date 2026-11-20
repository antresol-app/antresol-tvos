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
        /// The server's category list, to name `filter` in the player.
        var categories: [ChannelCategory] = []
    }

    /// A trailer the server plays itself (`Trailer.play`), over the title it belongs to.
    struct TrailerRequest: Identifiable, Hashable {
        let id = UUID()
        let trailer: Trailer
        let card: Card
    }

    /// A stream an addon's way started (`x/app/run`): played through the core's input player, or
    /// directly. `run` is what asked for it, to ask again for a fresh link.
    struct WayRequest: Identifiable, Hashable {
        enum Source: Hashable {
            /// `/api/play/input/{id}`.
            case input(String)
            /// The addon's own stream, with its session and progress.
            case stream(WayPlay)
        }

        let id = UUID()
        let launch: WayLaunch
        let source: Source
        let run: WayRunRequest
    }

    /// The request the player is showing, if any.
    var presented: Request?

    /// The addon stream the way player is showing, if any.
    var presentedWay: WayRequest?

    /// The trailer the trailer player is showing, if any.
    var presentedTrailer: TrailerRequest?

    /// The live channel the live player is showing, if any.
    var presentedChannel: LiveRequest?

    /// A full-screen player (video, trailer or live) covers the tabs. They stay alive
    /// under it, so their timers check this before doing work nobody sees.
    var isPresenting: Bool {
        presented != nil || presentedTrailer != nil || presentedChannel != nil || presentedWay != nil
    }

    /// Incremented each time the player closes; pages observe it to reload progress.
    private(set) var completedSessions = 0

    private var mediaKeys: MediaKeyStore?
    private var mediaKeyToken: String?

    func play(_ card: Card, from start: StartPoint = .resume, fileId: Int? = nil) {
        presented = Request(card: card, start: start, fileId: fileId)
    }

    /// Opens the live player on `channel`; channel up / down moves through the channels of
    /// `filter`, in the list's order.
    func watch(_ channel: Channel, channels: [Channel], filter: ChannelFilter = .all, categories: [ChannelCategory] = []) {
        presentedChannel = LiveRequest(channel: channel, channels: channels, filter: filter, categories: categories)
    }

    /// Opens the player of a stream an addon's way started.
    func playWay(_ launch: WayLaunch, source: WayRequest.Source, run: WayRunRequest) {
        presentedWay = WayRequest(launch: launch, source: source, run: run)
    }

    /// The way player of `request` closed. Only that player's own presentation is cleared: a newer
    /// one stays up. Its progress was written (to the library item, for an input that names one),
    /// so pages reload as after any other player.
    func wayPlayerDidClose(_ request: WayRequest) {
        if presentedWay?.id == request.id { presentedWay = nil }
        completedSessions += 1
    }

    /// Opens the trailer player. A trailer is not a playback session: no progress, no
    /// Continue Watching, no Up Next, so `completedSessions` stays as it is.
    func playTrailer(_ trailer: Trailer, of card: Card) {
        presentedTrailer = TrailerRequest(trailer: trailer, card: card)
    }

    /// The live player closed. `completedSessions` is left alone: a channel is not a
    /// playback session, nothing of the library changed (TV is TV).
    /// Only `request`'s own player clears the presentation: a newer one stays up.
    func liveChannelDidClose(_ request: LiveRequest) {
        if presentedChannel?.id == request.id { presentedChannel = nil }
        liveSessions += 1
    }

    /// Incremented each time the live player closes, so the TV tab can refresh its list
    /// (favourites and the last channel may have changed there).
    private(set) var liveSessions = 0

    /// The player of `request` closed. It may report late (its last progress write is
    /// awaited first), so a request started meanwhile is left presented.
    func playerDidClose(_ request: Request) {
        if presented?.id == request.id { presented = nil }
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
