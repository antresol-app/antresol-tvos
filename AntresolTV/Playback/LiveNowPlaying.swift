import AntresolKit
import MediaPlayer

/// The system's Now Playing for the live player: the programme, the channel and the live
/// flag (no scrubber, no time left), with the programme's backdrop as artwork. What was
/// there before (music, paused) comes back when the player closes.
@MainActor
final class LiveNowPlaying {
    private var previous: [String: Any]?
    private var client: APIClient?
    private var artworkPath = ""
    private var artwork: MPMediaItemArtwork?
    private var artworkTask: Task<Void, Never>?

    func begin(client: APIClient?) {
        self.client = client
        previous = MPNowPlayingInfoCenter.default().nowPlayingInfo
    }

    func update(channel: Channel, program: ChannelProgram?, isPlaying: Bool = false) {
        var info: [String: Any] = [
            MPNowPlayingInfoPropertyIsLiveStream: true,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.video.rawValue,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
            MPMediaItemPropertyTitle: program?.fullTitle ?? channel.name,
            MPMediaItemPropertyArtist: channel.label,
        ]
        let path = program?.backdrop ?? ""
        if path == artworkPath, let artwork {
            info[MPMediaItemPropertyArtwork] = artwork
        } else if path != artworkPath {
            loadArtwork(path)
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func loadArtwork(_ path: String) {
        artworkPath = path
        artwork = nil
        artworkTask?.cancel()
        guard let client else { return }
        artworkTask = Task { [weak self] in
            guard let artwork = await ImagePipeline.shared.nowPlayingArtwork(path, client: client),
                  !Task.isCancelled, let self, self.artworkPath == path
            else { return }
            self.artwork = artwork
            let center = MPNowPlayingInfoCenter.default()
            guard var info = center.nowPlayingInfo, info[MPNowPlayingInfoPropertyIsLiveStream] as? Bool == true else { return }
            info[MPMediaItemPropertyArtwork] = artwork
            center.nowPlayingInfo = info
        }
    }

    func end() {
        artworkTask?.cancel()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = previous
    }
}
