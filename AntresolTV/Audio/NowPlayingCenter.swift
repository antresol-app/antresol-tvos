import AntresolKit
import MediaPlayer
import UIKit

/// Publishes the audio player's state to the system (`MPNowPlayingInfoCenter`) and routes
/// the system's remote commands (Siri Remote while the app is in the background, Control
/// Center, AirPlay receivers) back to the player.
@MainActor
final class NowPlayingCenter {
    private unowned let player: AudioPlayer
    private var artworkPath: String?
    private var artwork: MPMediaItemArtwork?
    private var artworkTask: Task<Void, Never>?
    /// Registered remote-command handlers, removed again by `invalidate()`.
    private var commandTargets: [(command: MPRemoteCommand, target: Any)] = []

    init(player: AudioPlayer) {
        self.player = player
    }

    /// Rewrites the Now Playing info from the player's current state.
    func update() {
        guard let item = player.current else {
            clear()
            return
        }
        registerCommands()
        configureCommands()
        var info: [String: Any] = [
            MPMediaItemPropertyMediaType: MPMediaType.music.rawValue,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
            MPNowPlayingInfoPropertyPlaybackRate: player.isPlaying ? Double(player.player.rate) : 0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
        ]
        info[MPMediaItemPropertyTitle] = item.title
        info[MPMediaItemPropertyArtist] = item.artist
        info[MPMediaItemPropertyAlbumTitle] = item.album
        info[MPMediaItemPropertyPlaybackDuration] = player.durationSec
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = player.position
        if let index = player.queue.currentIndex {
            info[MPNowPlayingInfoPropertyPlaybackQueueIndex] = index
            info[MPNowPlayingInfoPropertyPlaybackQueueCount] = player.queue.count
        }
        if artworkPath == item.artwork, let artwork {
            info[MPMediaItemPropertyArtwork] = artwork
        } else {
            loadArtwork(item.artwork)
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    func clear() {
        artworkTask?.cancel()
        artworkPath = nil
        artwork = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    private func loadArtwork(_ path: String) {
        guard artworkPath != path else { return }
        artworkPath = path
        artwork = nil
        artworkTask?.cancel()
        guard let client = player.client, let url = client.urls.image(path) else { return }
        artworkTask = Task {
            guard let image = await ImagePipeline.shared.image(for: url, headers: client.authorizationHeaders(for: url), maxPixelSize: 800),
                  !Task.isCancelled, artworkPath == path
            else { return }
            artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            update()
        }
    }

    // MARK: Remote commands

    /// Removes the remote-command handlers from the shared command center; the player
    /// calls it when it is shut down (a new profile gets a new player).
    func invalidate() {
        clear()
        for entry in commandTargets {
            entry.command.removeTarget(entry.target)
        }
        commandTargets = []
    }

    private func registerCommands() {
        guard commandTargets.isEmpty else { return }
        let center = MPRemoteCommandCenter.shared()
        add(center.playCommand) { player, _ in player.resume() }
        add(center.pauseCommand) { player, _ in player.pause() }
        add(center.togglePlayPauseCommand) { player, _ in player.togglePlayPause() }
        add(center.nextTrackCommand) { player, _ in player.next() }
        add(center.previousTrackCommand) { player, _ in player.previous() }
        add(center.changePlaybackPositionCommand) { player, event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return }
            player.seek(to: event.positionTime)
        }
    }

    private func add(_ command: MPRemoteCommand, _ action: @escaping @MainActor (AudioPlayer, MPRemoteCommandEvent) -> Void) {
        commandTargets.append((command, command.addTarget(handler: target(action))))
    }

    /// Next/previous song; no skip intervals or speed for music.
    private func configureCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.skipForwardCommand.isEnabled = false
        center.skipBackwardCommand.isEnabled = false
        center.changePlaybackRateCommand.isEnabled = false
        center.nextTrackCommand.isEnabled = player.queue.nextIndex != nil
        center.previousTrackCommand.isEnabled = true
    }

    /// A command handler. Remote commands arrive on the main thread.
    private func target(_ action: @escaping @MainActor (AudioPlayer, MPRemoteCommandEvent) -> Void) -> (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus {
        { [weak self] event in
            MainActor.assumeIsolated {
                guard let player = self?.player, player.hasContent else { return .noActionableNowPlayingItem }
                action(player, event)
                return .success
            }
        }
    }
}
