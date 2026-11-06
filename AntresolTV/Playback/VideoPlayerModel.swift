import AVFoundation
import AVKit
import AntresolKit
import Foundation
import Observation
import UIKit
import VideoToolbox

/// One playback screen: resolves what to play, offers to resume, asks the server how to
/// play it (`/api/play`), drives an `AVPlayer` with the media-key URL and keeps the
/// server in sync — progress every 10 s and on pause, HLS keepalive, session cleanup.
/// It also owns the transport-bar menus (audio, subtitles, quality), the side-loaded
/// WebVTT subtitles and the "Up Next" episode proposal.
@MainActor
@Observable
final class VideoPlayerModel {
    enum State: Equatable {
        case preparing
        /// Waiting for "Resume from …" or "Start Over".
        case resumePrompt(positionSec: Double)
        case playing
        case failed(String)
    }

    /// The next episode of a series, offered near the end of the current one.
    struct UpNextOffer {
        let episode: EpisodeCard
        let title: String
        let overview: String
        let image: UIImage?
    }

    private(set) var state: State = .preparing
    /// The item being played (or prepared): used for titles and backgrounds.
    private(set) var card: Card
    private(set) var durationSec: Double = 0
    /// Becomes true when playback is over; the screen then closes itself.
    private(set) var didFinish = false
    /// A new stream is being prepared (track, quality or episode change).
    private(set) var isSwitching = false
    /// A short message about a failed track or quality change.
    private(set) var notice: String?
    /// What the transport-bar menus show.
    private(set) var menus = PlayerMenuState()
    /// The subtitle cue on screen, if any.
    private(set) var subtitleText: String?
    /// Paused: the transport bar is up, so subtitles move above it.
    private(set) var isPaused = false

    let player = AVPlayer()

    private let request: PlaybackCoordinator.Request
    private let preferences = PlayerPreferences()
    private weak var appState: AppState?
    private weak var coordinator: PlaybackCoordinator?
    private var client: APIClient? { appState?.client }

    private var item: ItemDetail?
    private var file: FileInfo?
    private var session: VideoPlaybackSession?
    private var reporter: PlaybackProgressReporter?
    private var source: PlaybackSource?
    private var options = PlaybackOptions()
    private var cues: [SubtitleCue] = []
    private var metadata: [AVMetadataItem] = []
    private var upNext: UpNextOffer?
    private var upNextDeclined = false
    private var lastRecovery: Date?
    private var isStopped = false
    /// Where playback should (re)start: the requested start, updated when the item is torn
    /// down after a failure, so Try Again resumes there and not at 0.
    private var requestedPosition: Double = 0
    /// The player item still waiting for its initial seek; until then the player's time is
    /// not the file position, so progress reads `source.startPosition` instead.
    private var pendingSeek: (item: ObjectIdentifier, playerTime: Double, autoplay: Bool)?
    /// Track and quality choices not yet applied; menu picks made during a switch add up here.
    private var pendingOptions: PlaybackOptions?
    private var isApplyingOptions = false
    /// A recovery (new server session after an error or expiry) is in flight.
    private var isRecovering = false
    /// The app is in the background and the HLS session was released.
    private var isSuspended = false

    private var timeObserver: Any?
    private var notificationObservers: [NSObjectProtocol] = []
    private var keyValueObservers: [NSKeyValueObservation] = []
    private var subtitleTask: Task<Void, Never>?
    private var sideTasks: [Task<Void, Never>] = []

    init(request: PlaybackCoordinator.Request) {
        self.request = request
        self.card = request.card
    }

    // MARK: - Lifecycle

    func start(appState: AppState, coordinator: PlaybackCoordinator) async {
        self.appState = appState
        self.coordinator = coordinator
        await open(request.card, from: request.start)
    }

    /// Retries after an error: from the last known (or requested) position.
    func retry() async {
        if let item, item.id == card.id {
            await begin(at: currentFilePosition ?? requestedPosition)
        } else {
            // Nothing resolved yet for this card (first open, or a failed episode switch).
            await open(card, from: card.id == request.card.id ? request.start : .resume)
        }
    }

    /// The answer to the resume prompt.
    func choose(resume: Bool) async {
        guard case .resumePrompt(let position) = state else { return }
        await begin(at: resume ? position : 0)
    }

    /// Writes the final position and releases the server session. Safe to call twice.
    func stop() async {
        guard !isStopped else { return }
        isStopped = true
        player.pause()
        await saveFinalPosition(atEnd: false)
        teardownPlayerItem()
        sideTasks.forEach { $0.cancel() }
        await session?.stop()
    }

    /// The app went to the background: saves the position and releases the HLS session,
    /// which counts toward the profile's limit (§5.6). Direct play keeps its item.
    func suspend() async {
        flushProgress()
        guard !isStopped, !isSuspended, state == .playing, source?.hlsSessionID != nil, let session else { return }
        isSuspended = true
        requestedPosition = currentFilePosition ?? requestedPosition
        player.pause()
        await session.stop()
    }

    /// The app is active again: starts a fresh session where playback was, paused.
    func resumeFromBackground() async {
        guard isSuspended else { return }
        isSuspended = false
        await restart(reason: nil, at: requestedPosition, autoplay: false)
    }

    /// Saves the position now (pause, app going to the background).
    func flushProgress() {
        guard let reporter, let position = currentFilePosition else { return }
        let durationMs = Int(durationSec * 1000)
        Task {
            await reporter.update(positionMs: Int(position * 1000), durationMs: durationMs)
            await reporter.flush()
        }
    }

    // MARK: - Menus

    func selectAudio(_ index: Int) {
        guard index != menus.audioIndex, let track = menus.audio.first(where: { $0.index == index }) else { return }
        preferences.audioLanguage = TrackLabels.normalizedLanguage(track.language)
        requestOptions { $0.audioIndex = index }
    }

    func selectQuality(_ quality: VideoQuality) {
        guard quality != menus.quality else { return }
        preferences.quality = quality
        requestOptions { $0.quality = quality }
    }

    /// Shows a text subtitle, burns in an image subtitle, or turns subtitles off (`nil`).
    func selectSubtitle(_ index: Int?) {
        guard index != menus.subtitleIndex else { return }
        let track = index.flatMap { index in menus.subtitles.first { $0.index == index } }
        preferences.subtitleLanguage = track.flatMap { TrackLabels.normalizedLanguage($0.language) }
        showSubtitle(track)
    }

    // MARK: - Up Next

    func acceptUpNext() {
        guard let offer = upNext else { return }
        upNext = nil
        Task {
            await finishCurrent(atEnd: false)
            await open(offer.episode.card, from: .resume)
        }
    }

    func declineUpNext() {
        upNextDeclined = true
    }

    /// The offered episode's synopsis, for the Up Next panel.
    var upNextOverview: String {
        upNext?.overview ?? ""
    }

    /// When the next episode starts by itself (the end of this one), for the panel's
    /// countdown; nil when autoplay is off.
    var upNextAutoplayDate: Date? {
        guard preferences.autoplayNext, let position = currentFilePosition, durationSec > position else { return nil }
        return Date().addingTimeInterval(durationSec - position)
    }

    /// The Up Next panel while it is on screen; reaching the end accepts through it so
    /// the player dismisses it the usual way.
    @ObservationIgnored weak var proposalController: AVContentProposalViewController?

    // MARK: - Opening an item

    private func open(_ target: Card, from start: PlaybackCoordinator.StartPoint) async {
        guard let client else { return }
        card = target
        if state == .playing {
            isSwitching = true
        } else {
            state = .preparing
        }
        do {
            let detail = try await playableItem(for: target, client: client)
            // The chosen version applies to the requested item, not to later episodes.
            let chosen = detail.id == request.card.id ? request.fileId : nil
            guard let file = detail.files.first(where: { $0.id == chosen }) ?? detail.primaryFile else {
                throw PlayerError.nothingToPlay
            }
            item = detail
            self.file = file
            card = detail.card
            durationSec = Double(file.durationMs ?? 0) / 1000
            metadata = Self.metadata(for: detail)
            loadArtwork(for: detail, client: client)
            var position: Double = 0
            if start != .beginning {
                position = ResumePolicy.videoStartSec(try? await client.progress(itemId: detail.id))
            }
            if start == .ask, position >= 5 {
                isSwitching = false
                state = .resumePrompt(positionSec: position)
                return
            }
            await begin(at: position)
        } catch {
            fail(error)
        }
    }

    /// Starts a server session for the current file at `position` (file seconds).
    private func begin(at position: Double) async {
        guard let client, let coordinator, let item, let file else { return }
        requestedPosition = position
        if state != .playing { state = .preparing }
        pendingOptions = nil
        await session?.stop()
        await reporter?.stop()
        options = PlaybackOptions(
            quality: preferences.quality == .auto ? nil : preferences.quality,
            audioIndex: preferences.audioIndex(for: file.audio)
        )
        let session = VideoPlaybackSession(
            client: client,
            mediaKeys: coordinator.mediaKeyStore(for: client),
            fileId: file.id,
            caps: Self.caps
        )
        await session.onEnded { [weak self] end in
            Task { @MainActor in
                switch end {
                case .expired:
                    await self?.restart(reason: nil)
                case .unauthorized:
                    self?.fail(APIError.unauthorized(message: nil))
                }
            }
        }
        self.session = session
        do {
            let source = try await session.start(at: position, options: options)
            guard !isStopped else {
                await session.stop()
                return
            }
            isSuspended = false
            let reporter = PlaybackProgressReporter(client: client, itemId: item.id)
            self.reporter = reporter
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
            upNext = nil
            upNextDeclined = false
            lastRecovery = nil
            notice = nil
            apply(source)
            load(source)
            await reporter.start()
            isSwitching = false
            state = .playing
            showSubtitle(preferences.subtitle(for: menus.subtitles))
            prepareUpNext(after: item, client: client)
        } catch {
            fail(error)
        }
    }

    /// Movies and episodes play themselves; a series or season plays its next episode.
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

    // MARK: - Stream changes

    /// Queues a track or quality change. Changes run one at a time and each request is
    /// built from every pick so far, so a quick audio pick then quality pick keeps both.
    private func requestOptions(_ change: (inout PlaybackOptions) -> Void) {
        var next = pendingOptions ?? options
        change(&next)
        pendingOptions = next
        guard !isApplyingOptions else { return }
        isApplyingOptions = true
        isSwitching = true
        notice = nil
        Task {
            while !isStopped, let target = pendingOptions {
                if target == options {
                    pendingOptions = nil
                    break
                }
                await switchStream(target)
                if pendingOptions == target { pendingOptions = nil }
            }
            pendingOptions = nil
            isApplyingOptions = false
            isSwitching = isRecovering
        }
    }

    /// Re-requests the stream at the current position with new options (audio track,
    /// quality, burned-in subtitle); the server replaces the HLS session.
    private func switchStream(_ newOptions: PlaybackOptions) async {
        guard let session, state == .playing, !isSuspended, let position = currentFilePosition else { return }
        let wasPlaying = player.rate > 0 || pendingSeek?.autoplay == true
        do {
            let fresh = try await session.start(at: position, options: newOptions)
            guard !isStopped, state == .playing else { return }
            options = newOptions
            apply(fresh)
            load(fresh, autoplay: wasPlaying)
        } catch is CancellationError {
            return
        } catch {
            guard !isStopped else { return }
            if let message = appState?.message(for: error) {
                notice = message
            }
        }
    }

    /// Starts a new server session: after the HLS session expired (`reason == nil`), the
    /// player failed, the app came back from the background, or the user scrubbed outside
    /// the produced part of a growing playlist (`position`). A second failure within 30 s
    /// is shown as an error instead. Duplicate failure signals are ignored while one
    /// recovery is in flight.
    private func restart(reason: Error?, at position: Double? = nil, autoplay: Bool? = nil) async {
        guard !isStopped, !isSuspended, !isRecovering, state == .playing, let session else { return }
        if let reason {
            if let lastRecovery, Date().timeIntervalSince(lastRecovery) < 30 {
                fail(reason)
                return
            }
            lastRecovery = Date()
        }
        let position = position ?? currentFilePosition ?? requestedPosition
        // A failed item has stopped by itself; otherwise keep the user's play/pause state.
        let play = autoplay ?? (reason != nil || player.timeControlStatus != .paused || pendingSeek?.autoplay == true)
        isRecovering = true
        isSwitching = true
        defer {
            isRecovering = false
            isSwitching = isApplyingOptions
        }
        do {
            let fresh = try await session.start(at: position, options: options)
            guard !isStopped, !isSuspended, state == .playing else { return }
            apply(fresh)
            load(fresh, autoplay: play)
        } catch is CancellationError {
            return
        } catch {
            fail(error)
        }
    }

    /// Decides where a transport-bar seek goes. A growing (EVENT) playlist only covers
    /// what the server has produced since its start, so a seek outside it asks the server
    /// for a new session at the target (`replaceSession`, §5.4) and the player stays put
    /// until that stream loads.
    func resolveUserSeek(from oldTime: CMTime, to targetTime: CMTime) -> CMTime {
        guard let source, source.mode.isHLS, targetTime.isNumeric else { return targetTime }
        let target = source.filePosition(playerTime: targetTime.seconds)
        if source.canSeekInPlayer(toFilePosition: target) { return targetTime }
        let seekable = player.currentItem?.seekableTimeRanges.map(\.timeRangeValue) ?? []
        if target >= source.timelineOffset, seekable.contains(where: { $0.containsTime(targetTime) }) {
            return targetTime
        }
        Task { await restart(reason: nil, at: min(max(0, target), max(0, durationSec - 1)), autoplay: true) }
        return oldTime
    }

    /// Takes the server's view of the stream: duration, tracks and applied choices.
    private func apply(_ source: PlaybackSource) {
        self.source = source
        let response = source.response
        if response.durationMs > 0 { durationSec = Double(response.durationMs) / 1000 }
        let audio = response.audio.isEmpty ? (file?.audio ?? []) : response.audio
        let subtitles = response.subtitles.isEmpty ? (file?.subs ?? []) : response.subtitles
        let burned = response.burnedSubtitle
        menus = PlayerMenuState(
            audio: audio,
            audioIndex: audio.isEmpty ? nil : response.audioIndex,
            subtitles: subtitles.filter { $0.isText || $0.burnIn },
            subtitleIndex: burned ?? (menus.subtitleIndex.flatMap { index in
                subtitles.contains { $0.index == index && $0.isText } ? index : nil
            }),
            quality: VideoQuality(rawValue: response.quality.selected) ?? options.quality ?? .auto,
            appliedQuality: response.quality.applied
        )
    }

    // MARK: - Subtitles

    private func showSubtitle(_ track: SubtitleTrack?) {
        subtitleTask?.cancel()
        cues = []
        subtitleText = nil
        let burned = (pendingOptions ?? options).burnSubtitle
        menus.subtitleIndex = track?.index
        guard let track else {
            if burned != nil { restream(burning: nil) }
            return
        }
        if track.burnIn {
            restream(burning: track.index)
            return
        }
        if burned != nil { restream(burning: nil) }
        guard let path = track.url, let client else { return }
        subtitleTask = Task { [weak self] in
            do {
                let cues = try await client.subtitleCues(path: path)
                guard !Task.isCancelled, let self else { return }
                self.cues = cues
                self.updateSubtitle()
            } catch {
                guard !Task.isCancelled, let self else { return }
                self.menus.subtitleIndex = nil
                self.notice = String(localized: "Subtitles could not be loaded.", bundle: .localized)
            }
        }
    }

    private func restream(burning index: Int?) {
        requestOptions { $0.burnSubtitle = index }
    }

    private func updateSubtitle() {
        guard !cues.isEmpty, let position = currentFilePosition else {
            if subtitleText != nil { subtitleText = nil }
            return
        }
        let text = WebVTT.cue(at: position, in: cues)?.text
        if text != subtitleText { subtitleText = text }
    }

    // MARK: - Up Next

    private func prepareUpNext(after item: ItemDetail, client: APIClient) {
        guard item.kind == .episode, let seriesId = item.seriesId else { return }
        let task = Task { [weak self] in
            guard let series = try? await client.item(id: seriesId),
                  let next = UpNext.episode(after: item.id, in: series.seasons)
            else { return }
            var image: UIImage?
            let path = next.card.backdrop.isEmpty ? next.card.poster : next.card.backdrop
            if !path.isEmpty, let url = client.urls.image(path) {
                image = await ImagePipeline.shared.image(for: url, headers: client.authorizationHeaders(for: url), maxPixelSize: 800)
            }
            guard !Task.isCancelled, let self, self.item?.id == item.id else { return }
            let label = String(localized: "S\(next.seasonNo), E\(next.episodeNo)", bundle: .localized)
            self.upNext = UpNextOffer(
                episode: next,
                title: next.card.title.isEmpty ? label : "\(label) · \(next.card.title)",
                overview: next.overview ?? "",
                image: image
            )
            self.attachProposal()
        }
        sideTasks.append(task)
    }

    /// Hands the offer to the current player item as its next-content proposal; the
    /// player view presents it at the transition time.
    private func attachProposal() {
        guard let offer = upNext, !upNextDeclined, let source, let playerItem = player.currentItem,
              let fileTime = UpNext.proposalTime(durationSec: durationSec)
        else { return }
        let playerTime = source.playerTime(filePosition: fileTime)
        guard playerTime > 0 else { return }
        let proposal = AVContentProposal(
            contentTimeForTransition: CMTime(seconds: playerTime, preferredTimescale: 600),
            title: offer.title,
            previewImage: offer.image
        )
        // Autoplay happens when the episode ends (`playbackEnded`), not on a system timer.
        proposal.automaticAcceptanceInterval = 0
        playerItem.nextContentProposal = proposal
    }

    /// Ends the current episode: final progress, watched mark when finished, and
    /// release of the server session.
    private func finishCurrent(atEnd: Bool) async {
        guard let item else { return }
        upNext = nil
        let position = atEnd ? durationSec : (currentFilePosition ?? durationSec)
        player.pause()
        await saveFinalPosition(atEnd: atEnd)
        teardownPlayerItem()
        reporter = nil
        await session?.stop()
        session = nil
        if UpNext.isFinished(positionSec: position, durationSec: durationSec) {
            try? await client?.setWatched(itemId: item.id, true)
        }
    }

    private func playbackEnded() {
        if upNext != nil, !upNextDeclined, preferences.autoplayNext {
            proposalController?.dismissContentProposal(for: .accept, animated: true, completion: nil)
            acceptUpNext()
            return
        }
        Task {
            await finishCurrent(atEnd: true)
            didFinish = true
        }
    }

    // MARK: - Player item

    private func load(_ source: PlaybackSource, autoplay: Bool = true) {
        teardownPlayerItem()
        let playerItem = AVPlayerItem(asset: Self.asset(for: source, client: client))
        playerItem.externalMetadata = metadata
        let itemID = ObjectIdentifier(playerItem)
        let seek = source.initialPlayerSeek
        // Seeking and playing wait for `readyToPlay`: a seek sent earlier can be dropped,
        // and until it lands the player's time is not the resume position.
        pendingSeek = seek > 0 ? (itemID, seek, autoplay) : nil
        player.replaceCurrentItem(with: playerItem)
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.recordPosition()
                self?.updateSubtitle()
            }
        }
        let center = NotificationCenter.default
        notificationObservers = [
            center.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: playerItem, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.playbackEnded() }
            },
            center.addObserver(forName: AVPlayerItem.failedToPlayToEndTimeNotification, object: playerItem, queue: .main) { [weak self] note in
                let error = note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
                Task { @MainActor in await self?.itemFailed(itemID, error: error) }
            },
        ]
        keyValueObservers = [
            playerItem.observe(\.status, options: [.new]) { [weak self] item, _ in
                let status = item.status
                let error = item.error
                Task { @MainActor in
                    switch status {
                    case .readyToPlay: self?.itemReady(itemID)
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
        attachProposal()
        if autoplay, pendingSeek == nil { player.play() }
    }

    /// The media-key URL needs no headers for direct play and complete (VOD) playlists.
    /// A growing (EVENT) playlist lists segments without the key, so every request of
    /// that asset carries the Bearer header instead (§5.4).
    private static func asset(for source: PlaybackSource, client: APIClient?) -> AVURLAsset {
        guard source.mode.isHLS, !source.response.hlsComplete, let client else {
            return AVURLAsset(url: source.url)
        }
        return AVURLAsset(url: source.url, options: ["AVURLAssetHTTPHeaderFieldsKey": client.authorizationHeaders(for: source.url)])
    }

    private func isCurrentItem(_ id: ObjectIdentifier) -> Bool {
        player.currentItem.map(ObjectIdentifier.init) == id
    }

    /// Performs the initial seek once the item can seek, then starts playing.
    private func itemReady(_ id: ObjectIdentifier) {
        guard let pending = pendingSeek, pending.item == id, isCurrentItem(id) else { return }
        player.seek(
            to: CMTime(seconds: pending.playerTime, preferredTimescale: 600),
            toleranceBefore: .zero, toleranceAfter: .zero
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, let pending = self.pendingSeek, pending.item == id else { return }
                self.pendingSeek = nil
                if pending.autoplay, self.isCurrentItem(id), !self.isStopped { self.player.play() }
            }
        }
    }

    /// The item and its "failed to play to end" notification usually both report one
    /// failure; only the first signal for the current item starts a recovery.
    private func itemFailed(_ id: ObjectIdentifier, error: Error?) async {
        guard isCurrentItem(id) else { return }
        await restart(reason: error ?? PlayerError.playbackFailed)
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

    /// The file position of the player, if it has one.
    private var currentFilePosition: Double? {
        guard let source, player.currentItem != nil else { return nil }
        if pendingSeek != nil { return source.startPosition }
        let time = player.currentTime().seconds
        guard time.isFinite, player.currentItem != nil else { return nil }
        return source.filePosition(playerTime: time)
    }

    /// Hands the current file position to the progress reporter.
    private func recordPosition() {
        guard let reporter, let position = currentFilePosition else { return }
        let durationMs = Int(durationSec * 1000)
        Task { await reporter.update(positionMs: Int(position * 1000), durationMs: durationMs) }
    }

    /// Writes the last position (the full duration when the video played to its end)
    /// and stops periodic reporting.
    private func saveFinalPosition(atEnd: Bool) async {
        guard let reporter else { return }
        let durationMs = Int(durationSec * 1000)
        if atEnd, durationMs > 0 {
            await reporter.update(positionMs: durationMs, durationMs: durationMs)
        } else if let position = currentFilePosition {
            await reporter.update(positionMs: Int(position * 1000), durationMs: durationMs)
        }
        await reporter.stop()
    }

    /// Shows the error and releases everything that would keep running behind it: the
    /// HLS session (one of the profile's two), the progress timer and the player item.
    /// The last position is saved and kept for Try Again.
    private func fail(_ error: Error) {
        guard !Task.isCancelled, !isStopped else { return }
        isSwitching = false
        pendingOptions = nil
        player.pause()
        if let position = currentFilePosition { requestedPosition = position }
        let message = appState?.message(for: error)
        let reporter = self.reporter
        self.reporter = nil
        let session = self.session
        let positionMs = Int(requestedPosition * 1000)
        let durationMs = Int(durationSec * 1000)
        let hadStarted = source != nil
        teardownPlayerItem()
        source = nil
        Task {
            if let reporter {
                if hadStarted { await reporter.update(positionMs: positionMs, durationMs: durationMs) }
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

    /// Title, context line, description and genre for the player's info panel.
    private static func metadata(for item: ItemDetail) -> [AVMetadataItem] {
        var items = [metadataItem(.commonIdentifierTitle, item.title)]
        if !item.subtitle.isEmpty {
            items.append(metadataItem(.iTunesMetadataTrackSubTitle, item.subtitle))
        }
        if !item.overview.isEmpty {
            items.append(metadataItem(.commonIdentifierDescription, item.overview))
        }
        if let genre = item.genres.first {
            items.append(metadataItem(.quickTimeMetadataGenre, genre))
        }
        if let rating = item.rating, !rating.isEmpty {
            items.append(metadataItem(.iTunesMetadataContentRating, rating))
        }
        return items
    }

    /// Adds the poster (or backdrop) to the info panel once it has loaded.
    private func loadArtwork(for item: ItemDetail, client: APIClient) {
        let path = item.poster.isEmpty ? item.backdrop : item.poster
        guard !path.isEmpty, let url = client.urls.image(path) else { return }
        let task = Task { [weak self] in
            guard let image = await ImagePipeline.shared.image(for: url, headers: client.authorizationHeaders(for: url), maxPixelSize: 800),
                  let data = image.jpegData(compressionQuality: 0.85),
                  !Task.isCancelled, let self, self.item?.id == item.id
            else { return }
            let artwork = AVMutableMetadataItem()
            artwork.identifier = .commonIdentifierArtwork
            artwork.value = data as NSData
            artwork.dataType = kCMMetadataBaseDataType_JPEG as String
            artwork.extendedLanguageTag = "und"
            self.metadata.append(artwork)
            self.player.currentItem?.externalMetadata = self.metadata
        }
        sideTasks.append(task)
    }

    private static func metadataItem(_ identifier: AVMetadataIdentifier, _ value: String) -> AVMetadataItem {
        let item = AVMutableMetadataItem()
        item.identifier = identifier
        item.value = value as NSString
        item.extendedLanguageTag = "und"
        return item
    }

    /// What this Apple TV decodes: HEVC and AV1 only where there is a hardware decoder
    /// (Apple TV HD has neither and tops out at 1080p).
    private static let caps: DeviceCaps = {
        let hevc = VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC)
        let av1 = VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1)
        return .appleTV(maxHeight: hevc ? 2160 : 1080, hevc: hevc, av1: av1)
    }()
}

/// What the transport-bar menus show and which entries are selected.
struct PlayerMenuState: Equatable {
    var audio: [AudioTrack] = []
    var audioIndex: Int?
    /// Text tracks (side-loaded) and image tracks (burned in by the server).
    var subtitles: [SubtitleTrack] = []
    var subtitleIndex: Int?
    var quality: VideoQuality = .auto
    /// What the server uses, e.g. "original" or "720".
    var appliedQuality: String = "original"
}

enum PlayerError: LocalizedError {
    case nothingToPlay
    case playbackFailed

    var errorDescription: String? {
        switch self {
        case .nothingToPlay:
            return String(localized: "There is no playable file for this item.", bundle: .localized)
        case .playbackFailed:
            return String(localized: "The video stopped playing. Check the connection to the server and try again.", bundle: .localized)
        }
    }
}
