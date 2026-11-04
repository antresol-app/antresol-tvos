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
    private var commandsRegistered = false

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
        if let book = player.book {
            info[MPMediaItemPropertyTitle] = book.card.title
            info[MPMediaItemPropertyArtist] = item.artist
            if let chapter = player.currentChapter, !chapter.title.isEmpty {
                info[MPMediaItemPropertyAlbumTitle] = chapter.title
            }
            info[MPMediaItemPropertyPlaybackDuration] = Double(book.durationMs) / 1000
            info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = Double(player.bookPositionMs) / 1000
            if let chapter = player.currentChapter, let index = book.chapters.firstIndex(of: chapter) {
                info[MPNowPlayingInfoPropertyChapterNumber] = index
                info[MPNowPlayingInfoPropertyChapterCount] = book.chapters.count
            }
        } else {
            info[MPMediaItemPropertyTitle] = item.title
            info[MPMediaItemPropertyArtist] = item.artist
            info[MPMediaItemPropertyAlbumTitle] = item.album
            info[MPMediaItemPropertyPlaybackDuration] = player.durationSec
            info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = player.position
            if let index = player.queue.currentIndex {
                info[MPNowPlayingInfoPropertyPlaybackQueueIndex] = index
                info[MPNowPlayingInfoPropertyPlaybackQueueCount] = player.queue.count
            }
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
            guard let image = await ImagePipeline.shared.image(for: url, headers: client.authorizationHeaders, maxPixelSize: 800),
                  !Task.isCancelled, artworkPath == path
            else { return }
            artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            update()
        }
    }

    // MARK: Remote commands

    private func registerCommands() {
        guard !commandsRegistered else { return }
        commandsRegistered = true
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget(handler: target { player, _ in player.resume() })
        center.pauseCommand.addTarget(handler: target { player, _ in player.pause() })
        center.togglePlayPauseCommand.addTarget(handler: target { player, _ in player.togglePlayPause() })
        center.nextTrackCommand.addTarget(handler: target { player, _ in player.next() })
        center.previousTrackCommand.addTarget(handler: target { player, _ in player.previous() })
        center.skipForwardCommand.preferredIntervals = [30]
        center.skipForwardCommand.addTarget(handler: target { player, _ in player.skip(by: 30) })
        center.skipBackwardCommand.preferredIntervals = [15]
        center.skipBackwardCommand.addTarget(handler: target { player, _ in player.skip(by: -15) })
        center.changePlaybackPositionCommand.addTarget(handler: target { player, event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return }
            if player.book != nil {
                player.seek(toBookMs: Int(event.positionTime * 1000))
            } else {
                player.seek(to: event.positionTime)
            }
        })
        center.changePlaybackRateCommand.supportedPlaybackRates = AudioPlayer.speeds.map { NSNumber(value: $0) }
        center.changePlaybackRateCommand.addTarget(handler: target { player, event in
            guard let event = event as? MPChangePlaybackRateCommandEvent else { return }
            player.setSpeed(event.playbackRate)
        })
    }

    /// Music uses next/previous song; audiobooks use 15/30 s skips and chapter jumps.
    private func configureCommands() {
        let center = MPRemoteCommandCenter.shared()
        let isBook = player.book != nil
        center.skipForwardCommand.isEnabled = isBook
        center.skipBackwardCommand.isEnabled = isBook
        center.changePlaybackRateCommand.isEnabled = isBook
        center.nextTrackCommand.isEnabled = isBook ? !(player.book?.chapters.isEmpty ?? true) : player.queue.nextIndex != nil
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
