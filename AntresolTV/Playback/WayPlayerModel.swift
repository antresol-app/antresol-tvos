import AVFoundation
import AVKit
import AntresolKit
import Foundation
import Observation
import UIKit

/// One playback screen of a stream an addon's way started: through the core's input player
/// (`/api/play/input/{id}`, which may need a while to get ready), or the addon's own stream with its
/// session and progress (`x/app/progress`). It drives an `AVPlayer` with the media-key URL, side-loads
/// the stream's text subtitles, keeps the server told how far it is, and asks again for a fresh stream
/// when the link goes stale.
@MainActor
@Observable
final class WayPlayerModel {
    enum State: Equatable {
        case preparing
        case playing
        case failed(String)
    }

    private(set) var state: State = .preparing
    /// Becomes true when playback is over; the screen then closes itself.
    private(set) var didFinish = false
    /// A new stream is being asked for (after the old one failed or expired).
    private(set) var isSwitching = false
    /// The stream's text subtitles, and the one on screen.
    private(set) var subtitles: [SubtitleTrack] = []
    private(set) var subtitleIndex: Int?
    private(set) var subtitleText: String?
    private(set) var isPaused = false
    /// A short message about subtitles that did not load.
    private(set) var notice: String?

    let player = AVPlayer()
    let request: PlaybackCoordinator.WayRequest

    private weak var appState: AppState?
    private weak var coordinator: PlaybackCoordinator?
    private var client: APIClient? { appState?.client }
    private let preferences = PlayerPreferences()

    /// The input player's session (HLS keepalive and cleanup); nil for the addon's own stream.
    private var session: VideoPlaybackSession?
    private var reporter: PlaybackProgressReporter?
    private var source: PlaybackSource?
    /// The addon's own stream in use (it changes when a fresh one is asked for).
    private var stream: WayPlay?
    private var durationSec: Double = 0
    /// Where playback should (re)start: updated whenever it stops, so Try Again resumes there.
    private var requestedPosition: Double = 0
    private var metadata: [AVMetadataItem] = []
    private var cues: [SubtitleCue] = []
    private var pendingSeek: (item: ObjectIdentifier, playerTime: Double)?
    private var isStopped = false
    private var isRecovering = false
    private var lastRecovery: Date?

    private var timeObserver: Any?
    private var notificationObservers: [NSObjectProtocol] = []
    private var keyValueObservers: [NSKeyValueObservation] = []
    private var subtitleTask: Task<Void, Never>?

    init(request: PlaybackCoordinator.WayRequest) {
        self.request = request
    }

    private var launch: WayLaunch { request.launch }

    // MARK: - Lifecycle

    func start(appState: AppState, coordinator: PlaybackCoordinator) async {
        self.appState = appState
        self.coordinator = coordinator
        metadata = Self.metadata(for: launch.card)
        await open(at: nil, fresh: false)
    }

    /// Try Again: from where playback stopped, with a fresh stream for the addon's own.
    func retry() async {
        guard case .failed = state else { return }
        await open(at: requestedPosition, fresh: true)
    }

    /// Writes the final position and releases what the server holds. Safe to call twice.
    func stop() async {
        guard !isStopped else { return }
        isStopped = true
        player.pause()
        subtitleTask?.cancel()
        await saveFinalPosition(atEnd: false)
        teardownPlayerItem()
        await release()
    }

    /// The app went to the background: saves the position.
    func flushProgress() {
        guard let reporter, let position = currentFilePosition else { return }
        let durationMs = Int(durationSec * 1000)
        guard durationMs > 0 else { return }
        Task {
            await reporter.update(positionMs: min(Int(position * 1000), durationMs), durationMs: durationMs)
            await reporter.flush()
        }
    }

    /// Picks a subtitle track (`nil`: off) and remembers its language.
    func selectSubtitle(_ index: Int?) {
        guard index != subtitleIndex else { return }
        let track = index.flatMap { index in subtitles.first { $0.index == index } }
        preferences.subtitleLanguage = track.flatMap { TrackLabels.normalizedLanguage($0.language) }
        showSubtitle(track)
    }

    // MARK: - Opening the stream

    /// Asks the server for the stream and starts it at `position` (file seconds; the stream's own
    /// start when nil). `fresh` asks the addon for a new link first.
    private func open(at position: Double?, fresh: Bool) async {
        guard let client, let coordinator else { return }
        state = .preparing
        do {
            switch request.source {
            case .input(let id):
                try await openInput(id, at: position, client: client, coordinator: coordinator)
            case .stream(let first):
                var play = stream ?? first
                if fresh { play = try await freshStream(at: position ?? requestedPosition, client: client) }
                try await openStream(play, at: position, client: client, coordinator: coordinator)
            }
        } catch is CancellationError {
            // Closed while preparing.
        } catch {
            fail(error)
        }
    }

    private func openInput(_ id: String, at position: Double?, client: APIClient, coordinator: PlaybackCoordinator) async throws {
        let info = try? await client.inputInfo(id: id)
        let start = position ?? info?.startSec ?? 0
        requestedPosition = start
        await reporter?.stop()
        await session?.stop()
        let session = VideoPlaybackSession(
            client: client, mediaKeys: coordinator.mediaKeyStore(for: client), caps: PlayerDevice.caps
        ) { play in
            try await client.startInputPlay(id: id, play)
        }
        await session.onEnded { [weak self] end in
            Task { @MainActor in
                switch end {
                case .expired: await self?.restart(reason: nil)
                case .unauthorized: self?.fail(APIError.unauthorized(message: nil))
                }
            }
        }
        self.session = session
        let source = try await session.start(at: start)
        guard !isStopped else {
            await session.stop()
            return
        }
        reporter = PlaybackProgressReporter { positionMs, durationMs, keepalive in
            try await client.updateInputProgress(id: id, positionMs: positionMs, durationMs: durationMs, keepalive: keepalive)
        }
        begin(source)
    }

    private func openStream(_ play: WayPlay, at position: Double?, client: APIClient, coordinator: PlaybackCoordinator) async throws {
        let key = try await coordinator.mediaKeyStore(for: client).key()
        guard !isStopped else { return }
        guard let url = client.urls.playback(play.response, mediaKey: key) else {
            throw APIError.invalidURL(play.response.url)
        }
        let start = position ?? play.response.startSec
        requestedPosition = start
        stream = play
        await reporter?.stop()
        reporter = nil
        if let sessionId = play.session {
            let addon = launch.way.addonId
            let wayId = launch.way.way.id
            let target = launch.target
            let path = play.progress.path
            reporter = PlaybackProgressReporter(interval: play.progress.every) { positionMs, durationMs, _ in
                let finished = UpNext.isFinished(positionSec: Double(positionMs) / 1000, durationSec: Double(durationMs) / 1000)
                try await client.wayProgress(
                    addon: addon, path: path,
                    WayProgressUpdate(session: sessionId, way: wayId, target: target, positionMs: positionMs, durationMs: durationMs, finished: finished)
                )
            }
        }
        begin(PlaybackSource(response: play.response, url: url, startPosition: start))
    }

    /// `POST x/app/run` again for the same choice with `refresh`: a new link for a stream whose old
    /// one went stale (the media answered 410). The old session is closed.
    private func freshStream(at position: Double, client: APIClient) async throws -> WayPlay {
        var run = request.run
        run.refresh = true
        run.quick = request.run.ref == nil ? true : nil
        run.startSec = position > 0 ? position : nil
        guard case .play(let play) = try await client.wayRun(addon: launch.way.addonId, run) else {
            throw PlayerError.playbackFailed
        }
        if let old = stream?.session, old != play.session {
            try? await client.wayStopPlay(addon: launch.way.addonId, session: old)
        }
        return play
    }

    /// Starts `source` in the player and reports the stream as playing.
    private func begin(_ source: PlaybackSource) {
        self.source = source
        if source.response.durationMs > 0 { durationSec = Double(source.response.durationMs) / 1000 }
        subtitles = source.response.subtitles.filter(\.isText)
        isSwitching = false
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        load(source)
        state = .playing
        showSubtitle(preferences.subtitle(for: subtitles))
        if let reporter {
            Task { await reporter.start() }
        }
    }

    /// Takes the stream again at the player's position: after the server's session expired, the
    /// player failed (a stale link, a dropped connection) or the app came back. A second failure
    /// within 30 s is shown as an error instead.
    private func restart(reason: Error?, autoplay: Bool? = nil) async {
        guard !isStopped, !isRecovering, state == .playing, let client, let coordinator else { return }
        if let reason {
            if let lastRecovery, Date().timeIntervalSince(lastRecovery) < 30 {
                fail(reason)
                return
            }
            lastRecovery = Date()
        }
        let position = currentFilePosition ?? requestedPosition
        let play = autoplay ?? (reason != nil || player.timeControlStatus != .paused)
        isRecovering = true
        isSwitching = true
        defer {
            isRecovering = false
            isSwitching = false
        }
        do {
            switch request.source {
            case .input:
                guard let session else { return }
                let fresh = try await session.start(at: position)
                guard !isStopped, state == .playing else { return }
                self.source = fresh
                load(fresh, autoplay: play)
            case .stream:
                let renewed = try await freshStream(at: position, client: client)
                guard !isStopped, state == .playing else { return }
                try await openStream(renewed, at: position, client: client, coordinator: coordinator)
            }
        } catch is CancellationError {
            return
        } catch {
            fail(error)
        }
    }

    // MARK: - Subtitles

    private func showSubtitle(_ track: SubtitleTrack?) {
        subtitleTask?.cancel()
        cues = []
        subtitleText = nil
        subtitleIndex = track?.index
        guard let track, let path = track.url, let client else { return }
        subtitleTask = Task { [weak self] in
            do {
                let cues = try await client.subtitleCues(path: path)
                guard !Task.isCancelled, let self else { return }
                self.cues = cues
                self.updateSubtitle()
            } catch {
                guard !Task.isCancelled, let self else { return }
                self.subtitleIndex = nil
                self.notice = String(localized: "Subtitles could not be loaded.", bundle: .localized)
            }
        }
    }

    private func updateSubtitle() {
        guard !cues.isEmpty, let position = currentFilePosition else {
            if subtitleText != nil { subtitleText = nil }
            return
        }
        let text = WebVTT.cue(at: position, in: cues)?.text
        if text != subtitleText { subtitleText = text }
    }

    // MARK: - Player item

    private func load(_ source: PlaybackSource, autoplay: Bool = true) {
        teardownPlayerItem()
        let item = AVPlayerItem(asset: VideoPlayerModel.asset(for: source, client: client))
        item.externalMetadata = metadata
        let itemID = ObjectIdentifier(item)
        let seek = source.initialPlayerSeek
        // Seeking waits for `readyToPlay`: a seek sent earlier can be dropped.
        pendingSeek = seek > 0 ? (itemID, seek) : nil
        player.replaceCurrentItem(with: item)
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.recordPosition()
                self?.updateSubtitle()
            }
        }
        let center = NotificationCenter.default
        notificationObservers = [
            center.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.playbackEnded() }
            },
            center.addObserver(forName: AVPlayerItem.failedToPlayToEndTimeNotification, object: item, queue: .main) { [weak self] note in
                let error = note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
                Task { @MainActor in await self?.itemFailed(itemID, error: error) }
            },
        ]
        keyValueObservers = [
            item.observe(\.status, options: [.new]) { [weak self] item, _ in
                let status = item.status
                let error = item.error
                Task { @MainActor in
                    switch status {
                    case .readyToPlay: self?.itemReady(itemID, autoplay: autoplay)
                    case .failed: await self?.itemFailed(itemID, error: error)
                    default: break
                    }
                }
            },
            player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
                let paused = player.timeControlStatus == .paused
                Task { @MainActor in
                    guard let self else { return }
                    if self.isPaused != paused { self.isPaused = paused }
                    if paused { self.flushProgress() }
                }
            },
        ]
        if autoplay, pendingSeek == nil { player.play() }
    }

    private func isCurrentItem(_ id: ObjectIdentifier) -> Bool {
        player.currentItem.map(ObjectIdentifier.init) == id
    }

    /// Performs the initial seek once the item can seek, then starts playing.
    private func itemReady(_ id: ObjectIdentifier, autoplay: Bool) {
        guard let pending = pendingSeek, pending.item == id, isCurrentItem(id) else { return }
        player.seek(
            to: CMTime(seconds: pending.playerTime, preferredTimescale: 600),
            toleranceBefore: .zero, toleranceAfter: .zero
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, let pending = self.pendingSeek, pending.item == id else { return }
                self.pendingSeek = nil
                if autoplay, self.isCurrentItem(id), !self.isStopped { self.player.play() }
            }
        }
    }

    private func itemFailed(_ id: ObjectIdentifier, error: Error?) async {
        guard isCurrentItem(id) else { return }
        await restart(reason: error ?? PlayerError.playbackFailed)
    }

    private func playbackEnded() {
        Task {
            await saveFinalPosition(atEnd: true)
            didFinish = true
        }
    }

    private func teardownPlayerItem() {
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
        notificationObservers.forEach(NotificationCenter.default.removeObserver)
        notificationObservers = []
        keyValueObservers.forEach { $0.invalidate() }
        keyValueObservers = []
        player.replaceCurrentItem(with: nil)
        pendingSeek = nil
        subtitleText = nil
    }

    // MARK: - Position and progress

    /// The file position of the player, if it has one.
    private var currentFilePosition: Double? {
        guard let source, player.currentItem != nil else { return nil }
        if pendingSeek != nil { return source.startPosition }
        let time = player.currentTime().seconds
        guard time.isFinite else { return nil }
        return source.filePosition(playerTime: time)
    }

    /// The length of a stream that did not say it is the player's, once the player knows it.
    private func learnDuration() {
        guard durationSec <= 0, let source, let length = player.currentItem?.duration.seconds, length.isFinite, length > 0 else { return }
        durationSec = source.filePosition(playerTime: length)
    }

    /// Hands the current position to the progress reporter (once the length is known: the server
    /// refuses a position past the end).
    private func recordPosition() {
        learnDuration()
        guard let reporter, let position = currentFilePosition, durationSec > 0 else { return }
        let durationMs = Int(durationSec * 1000)
        Task { await reporter.update(positionMs: min(Int(position * 1000), durationMs), durationMs: durationMs) }
    }

    /// Writes the last position (the full length when the stream played to its end) and stops
    /// periodic reporting.
    private func saveFinalPosition(atEnd: Bool) async {
        guard let reporter else { return }
        learnDuration()
        let durationMs = Int(durationSec * 1000)
        if durationMs > 0 {
            if atEnd {
                await reporter.update(positionMs: durationMs, durationMs: durationMs)
            } else if let position = currentFilePosition {
                await reporter.update(positionMs: min(Int(position * 1000), durationMs), durationMs: durationMs)
            }
        }
        await reporter.stop()
        self.reporter = nil
    }

    /// Releases what the server holds for the stream: the core's HLS session of an input, or the
    /// addon's own session (`DELETE x/app/play/{session}`, errors ignored).
    private func release() async {
        await session?.stop()
        session = nil
        if let sessionId = stream?.session, let client {
            try? await client.wayStopPlay(addon: launch.way.addonId, session: sessionId)
        }
    }

    /// Shows the error and lets go of everything that would keep running behind it. The last
    /// position is saved and kept for Try Again.
    private func fail(_ error: Error) {
        guard !Task.isCancelled, !isStopped else { return }
        isSwitching = false
        player.pause()
        if let position = currentFilePosition { requestedPosition = position }
        let message = appState?.message(for: error)
        teardownPlayerItem()
        source = nil
        let reporter = self.reporter
        self.reporter = nil
        let session = self.session
        self.session = nil
        let positionMs = Int(requestedPosition * 1000)
        let durationMs = Int(durationSec * 1000)
        Task {
            if let reporter {
                if durationMs > 0 { await reporter.update(positionMs: min(positionMs, durationMs), durationMs: durationMs) }
                await reporter.stop()
            }
            await session?.stop()
        }
        guard let message else { return }
        if let apiError = error as? APIError, apiError.isTooManySessions {
            state = .failed(apiError.serverMessage ?? String(localized: "This profile is already watching on another device. Stop playback there and try again.", bundle: .localized))
        } else {
            state = .failed(message)
        }
    }

    // MARK: - Metadata

    /// Title and context line for the player's info panel.
    private static func metadata(for card: Card) -> [AVMetadataItem] {
        var items = [item(.commonIdentifierTitle, card.title)]
        if !card.subtitle.isEmpty {
            items.append(item(.iTunesMetadataTrackSubTitle, card.subtitle))
        }
        return items
    }

    private static func item(_ identifier: AVMetadataIdentifier, _ value: String) -> AVMetadataItem {
        let item = AVMutableMetadataItem()
        item.identifier = identifier
        item.value = value as NSString
        item.extendedLanguageTag = "und"
        return item
    }
}
