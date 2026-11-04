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
    private var reporter: ProgressReporter?
    private var source: PlaybackSource?
    private var options = PlaybackOptions()
    private var cues: [SubtitleCue] = []
    private var metadata: [AVMetadataItem] = []
    private var upNext: UpNextOffer?
    private var upNextDeclined = false
    private var lastRecovery: Date?
    private var isStopped = false

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

    /// Retries after an error: from the last known position when playback had begun.
    func retry() async {
        if item != nil {
            await begin(at: currentFilePosition ?? 0)
        } else {
            await open(request.card, from: request.start)
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
        var next = options
        next.audioIndex = index
        Task { await switchStream(next) }
    }

    func selectQuality(_ quality: VideoQuality) {
        guard quality != menus.quality else { return }
        preferences.quality = quality
        var next = options
        next.quality = quality
        Task { await switchStream(next) }
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
            guard let file = detail.primaryFile else { throw PlayerError.nothingToPlay }
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
        if state != .playing { state = .preparing }
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
        await session.onExpired { [weak self] in
            Task { @MainActor in await self?.restart(reason: nil) }
        }
        self.session = session
        do {
            let source = try await session.start(at: position, options: options)
            guard !isStopped else {
                await session.stop()
                return
            }
            let reporter = ProgressReporter(client: client, itemId: item.id)
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

    /// Re-requests the stream at the current position with new options (audio track,
    /// quality, burned-in subtitle); the server replaces the HLS session.
    private func switchStream(_ newOptions: PlaybackOptions) async {
        guard let session, let position = currentFilePosition else { return }
        isSwitching = true
        notice = nil
        let wasPlaying = player.rate > 0
        do {
            let fresh = try await session.start(at: position, options: newOptions)
            guard !isStopped else { return }
            options = newOptions
            apply(fresh)
            load(fresh, autoplay: wasPlaying)
        } catch {
            if let message = appState?.message(for: error) {
                notice = message
            }
        }
        isSwitching = false
    }

    /// Starts a new server session at the current position: after the HLS session
    /// expired (`reason == nil`) or the player failed. A second failure within 30 s
    /// is shown as an error instead.
    private func restart(reason: Error?) async {
        guard !isStopped, let session else { return }
        if reason != nil {
            if let lastRecovery, Date().timeIntervalSince(lastRecovery) < 30 {
                fail(reason ?? PlayerError.playbackFailed)
                return
            }
            lastRecovery = Date()
        }
        let position = currentFilePosition ?? 0
        isSwitching = true
        do {
            let fresh = try await session.start(at: position, options: options)
            guard !isStopped else { return }
            apply(fresh)
            load(fresh)
            isSwitching = false
        } catch {
            fail(error)
        }
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
        let burned = options.burnSubtitle
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
                self.notice = String(localized: "Subtitles could not be loaded.")
            }
        }
    }

    private func restream(burning index: Int?) {
        var next = options
        next.burnSubtitle = index
        Task { await switchStream(next) }
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
                image = await ImagePipeline.shared.image(for: url, headers: client.authorizationHeaders, maxPixelSize: 800)
            }
            guard !Task.isCancelled, let self, self.item?.id == item.id else { return }
            let label = String(localized: "S\(next.seasonNo), E\(next.episodeNo)")
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
        proposal.automaticAcceptanceInterval = preferences.autoplayNext ? 10 : 0
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
        if let offer = upNext, !upNextDeclined, preferences.autoplayNext {
            Task {
                await finishCurrent(atEnd: true)
                await open(offer.episode.card, from: .resume)
            }
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
        let playerItem = AVPlayerItem(url: source.url)
        playerItem.externalMetadata = metadata
        player.replaceCurrentItem(with: playerItem)
        let seek = source.initialPlayerSeek
        if seek > 0 {
            player.seek(to: CMTime(seconds: seek, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        }
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
                Task { @MainActor in await self?.restart(reason: error ?? PlayerError.playbackFailed) }
            },
        ]
        keyValueObservers = [
            playerItem.observe(\.status, options: [.new]) { [weak self] item, _ in
                guard item.status == .failed else { return }
                let error = item.error
                Task { @MainActor in await self?.restart(reason: error ?? PlayerError.playbackFailed) }
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
        if autoplay { player.play() }
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
        subtitleText = nil
    }

    /// The file position of the player, if it has one.
    private var currentFilePosition: Double? {
        guard let source else { return nil }
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

    private func fail(_ error: Error) {
        guard !Task.isCancelled, !isStopped else { return }
        isSwitching = false
        player.pause()
        recordPosition()
        guard let message = appState?.message(for: error) else { return }
        if let apiError = error as? APIError, apiError.isTooManySessions {
            state = .failed(apiError.serverMessage ?? String(localized: "This profile is already watching on another device. Stop playback there and try again."))
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
            guard let image = await ImagePipeline.shared.image(for: url, headers: client.authorizationHeaders, maxPixelSize: 800),
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
            return String(localized: "There is no playable file for this item.")
        case .playbackFailed:
            return String(localized: "The video stopped playing. Check the connection to the server and try again.")
        }
    }
}
