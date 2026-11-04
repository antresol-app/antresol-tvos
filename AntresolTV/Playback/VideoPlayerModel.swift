import AVFoundation
import AntresolKit
import Foundation
import Observation

/// One playback: resolves what to play, asks the server how (`/api/play`), drives an
/// `AVPlayer` with the media-key URL, reports progress every 10 s and cleans the HLS
/// session up when it closes. Audio/subtitle menus, quality and up-next come with the
/// full player (see NOTES.md).
@MainActor
@Observable
final class VideoPlayerModel {
    enum State: Equatable {
        case preparing
        case playing
        case failed(String)
    }

    private(set) var state: State = .preparing
    /// Becomes true when the item plays to its end; the screen then closes itself.
    private(set) var didPlayToEnd = false
    /// Title shown while preparing.
    private(set) var title: String

    let player = AVPlayer()

    private let request: PlaybackCoordinator.Request
    private var session: VideoPlaybackSession?
    private var reporter: ProgressReporter?
    private var source: PlaybackSource?
    private var durationMs = 0
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var metadata: [AVMetadataItem] = []
    private var isStopped = false

    init(request: PlaybackCoordinator.Request) {
        self.request = request
        self.title = request.card.title
    }

    func start(appState: AppState, coordinator: PlaybackCoordinator) async {
        guard let client = appState.client else { return }
        state = .preparing
        do {
            let target = try await playableItem(for: request.card, client: client)
            guard let file = target.primaryFile else { throw PlayerError.nothingToPlay }
            title = target.title
            metadata = Self.metadata(for: target)
            var startSec: Double = 0
            if request.start == .resume {
                startSec = ResumePolicy.videoStartSec(try? await client.progress(itemId: target.id))
            }
            let session = VideoPlaybackSession(
                client: client,
                mediaKeys: coordinator.mediaKeyStore(for: client),
                fileId: file.id
            )
            await session.onExpired { [weak self] in
                Task { @MainActor in await self?.restartAfterExpiry() }
            }
            self.session = session
            let source = try await session.start(at: startSec)
            guard !isStopped else {
                await session.stop()
                return
            }
            durationMs = source.response.durationMs > 0 ? source.response.durationMs : (file.durationMs ?? 0)
            let reporter = ProgressReporter(client: client, itemId: target.id)
            self.reporter = reporter
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
            load(source)
            await reporter.start()
            state = .playing
        } catch {
            guard !Task.isCancelled, !isStopped else { return }
            if let message = appState.message(for: error) {
                state = .failed(message)
            }
        }
    }

    /// Writes the final position and releases the server session. Safe to call twice.
    func stop() async {
        guard !isStopped else { return }
        isStopped = true
        player.pause()
        recordPosition()
        removeObservers()
        player.replaceCurrentItem(with: nil)
        await reporter?.stop()
        await session?.stop()
    }

    // MARK: - Private

    /// Movies and episodes play themselves; a series plays its next episode (or the first).
    private func playableItem(for card: Card, client: APIClient) async throws -> ItemDetail {
        let detail = try await client.item(id: card.id)
        switch detail.kind {
        case .series, .season:
            let episode = detail.next?.card
                ?? detail.seasons.lazy.flatMap(\.episodes).first?.card
            guard let episode else { throw PlayerError.nothingToPlay }
            return try await client.item(id: episode.id)
        default:
            return detail
        }
    }

    private func load(_ source: PlaybackSource) {
        removeObservers()
        self.source = source
        let item = AVPlayerItem(url: source.url)
        item.externalMetadata = metadata
        player.replaceCurrentItem(with: item)
        if source.initialPlayerSeek > 0 {
            player.seek(to: CMTime(seconds: source.initialPlayerSeek, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        }
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 1, preferredTimescale: 600), queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.recordPosition() }
        }
        endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.recordPosition(atEnd: true)
                self?.didPlayToEnd = true
            }
        }
        player.play()
    }

    /// Hands the current file position to the progress reporter.
    private func recordPosition(atEnd: Bool = false) {
        guard let source, let reporter else { return }
        let playerTime = player.currentTime().seconds
        guard playerTime.isFinite else { return }
        let positionMs = atEnd && durationMs > 0 ? durationMs : Int(source.filePosition(playerTime: playerTime) * 1000)
        let duration = durationMs
        Task { await reporter.update(positionMs: positionMs, durationMs: duration) }
    }

    /// The server dropped the HLS session (e.g. after a long pause): start a new one at
    /// the current position.
    private func restartAfterExpiry() async {
        guard !isStopped, let session, let source else { return }
        let position = source.filePosition(playerTime: player.currentTime().seconds)
        do {
            let fresh = try await session.start(at: position.isFinite ? position : 0)
            guard !isStopped else { return }
            load(fresh)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    private func removeObservers() {
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
    }

    /// Title and context line for the player's info panel.
    private static func metadata(for item: ItemDetail) -> [AVMetadataItem] {
        var items = [metadataItem(.commonIdentifierTitle, item.title)]
        if !item.subtitle.isEmpty {
            items.append(metadataItem(.iTunesMetadataTrackSubTitle, item.subtitle))
        }
        if !item.overview.isEmpty {
            items.append(metadataItem(.commonIdentifierDescription, item.overview))
        }
        return items
    }

    private static func metadataItem(_ identifier: AVMetadataIdentifier, _ value: String) -> AVMetadataItem {
        let item = AVMutableMetadataItem()
        item.identifier = identifier
        item.value = value as NSString
        item.extendedLanguageTag = "und"
        return item
    }
}

enum PlayerError: LocalizedError {
    case nothingToPlay

    var errorDescription: String? {
        String(localized: "There is no playable file for this item.")
    }
}
