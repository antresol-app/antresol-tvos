import AVFoundation
import AntresolKit
import Foundation
import MediaPlayer
import Observation
import UIKit

/// The live player of a channel («ТВ»): starts the channel's stream (waiting while the
/// server starts its encoder), plays it at the live edge and zaps to the neighbouring
/// channels of the list it was opened from (all, favourites or a theme) by number, or to a
/// channel picked in the mini-guide. The channel's guide (on now, next) and the list are
/// refreshed every 30 s.
///
/// TV is TV: every request goes through `ChannelService`. Nothing here reports progress or
/// playback, saves a resume point, marks anything watched, remembers tracks on the server
/// or scrobbles; the audio and subtitle picks live in this session only. The writes are the
/// star (favourites) and the last channel (on tune-in).
///
/// Zapping never goes black: there are two players, each with its own layer. The new
/// channel loads into the one underneath while the other holds its last frame (paused,
/// dimmed by the view); they swap once the new picture's first frame is ready.
@MainActor
@Observable
final class LivePlayerModel {
    enum State: Equatable {
        /// Asking the server for the stream, or waiting for its first frame;
        /// `isStarting` once the server said the channel is starting.
        case connecting(isStarting: Bool)
        case playing
        case failed(String)
    }

    private(set) var state: State = .connecting(isStarting: false)
    private(set) var channel: Channel
    /// Every channel the profile sees, by number.
    private(set) var channels: [Channel]
    /// The list the player was opened from: channel up / down stays inside it.
    let filter: ChannelFilter
    private(set) var guide: ChannelGuide?
    /// The options row (star, audio, subtitles, channels) under the banner has focus.
    private(set) var showsControls = false
    /// The audio or subtitle list opened from the options row.
    var openMenu: TrackMenuKind?
    /// The profile's audio and subtitle defaults.
    private(set) var prefs = PlaybackPrefs()
    /// The viewer's picks of this session (never sent anywhere).
    private(set) var selection = LiveTrackSelection()
    /// The renditions the stream on screen offers (HLS NAME and language).
    private(set) var audioOptions: [StreamOption] = []
    private(set) var subtitleOptions: [StreamOption] = []
    /// The subtitle cue on screen. The player's own rendering is off: the view draws it,
    /// lifted above the banner while that is up.
    private(set) var subtitleText: String?
    /// The channel banner (logo, what is on, next) is up.
    private(set) var showsInfo = true
    /// The mini-guide (the section's channels along the bottom) is up.
    private(set) var showsGuide = false
    private(set) var isPaused = false
    /// The previous channel's last frame is on screen while the new channel starts.
    private(set) var isHoldingFrame = false
    /// Which of `players` / `layers` is on screen.
    private(set) var front = 0

    /// Two players and their layers: the one on screen and the one a zap loads into.
    let players = [AVPlayer(), AVPlayer()]
    let layers: [AVPlayerLayer]

    private var player: AVPlayer { players[front] }

    @ObservationIgnored private weak var appState: AppState?
    @ObservationIgnored private weak var coordinator: PlaybackCoordinator?
    @ObservationIgnored private var startTask: Task<Void, Never>?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var hideTask: Task<Void, Never>?
    @ObservationIgnored private var swapTask: Task<Void, Never>?
    /// Per player: the observers of its current item.
    @ObservationIgnored private var keyValueObservers: [[NSKeyValueObservation]] = [[], []]
    @ObservationIgnored private var notificationObservers: [[NSObjectProtocol]] = [[], []]
    @ObservationIgnored private var nowPlaying = LiveNowPlaying()
    /// Per player: the legible output of its item and its delegate.
    @ObservationIgnored private var legibleReceivers: [LiveLegibleReceiver?] = [nil, nil]
    @ObservationIgnored private var isStopped = false
    @ObservationIgnored private var service: ChannelService?
    /// The programme the tracks were last chosen for.
    @ObservationIgnored private var tracksProgram: String?

    /// How long the banner stays up after a change.
    private static let infoDuration: Duration = .seconds(5)
    /// How long a ready item may wait for its layer's first frame before it is shown anyway.
    private static let firstFrameGrace: Duration = .milliseconds(1500)

    init(request: PlaybackCoordinator.LiveRequest) {
        channel = request.channel
        filter = request.filter
        var channels = request.channels.sorted(by: Channel.byNumber)
        if !channels.contains(where: { $0.id == request.channel.id }) {
            channels.append(request.channel)
            channels.sort(by: Channel.byNumber)
        }
        self.channels = channels
        layers = players.map { player in
            let layer = AVPlayerLayer(player: player)
            layer.videoGravity = .resizeAspect
            return layer
        }
    }

    /// What is on now and next: from the guide, else from the channel list.
    func onAir(at date: Date) -> (now: ChannelProgram?, next: ChannelProgram?) {
        if let guide, guide.channel.id == channel.id, !guide.programs.isEmpty {
            return guide.onAir(at: date)
        }
        return (channel.program(at: date), channel.upNext(at: date))
    }

    /// What channel up / down and the mini-guide go through: the list the player was opened
    /// from, by number (the current channel kept in its place).
    var zapList: [Channel] {
        filter.zapList(channels, current: channel)
    }

    // MARK: - Lifecycle

    func start(appState: AppState, coordinator: PlaybackCoordinator) {
        self.appState = appState
        self.coordinator = coordinator
        for player in players {
            player.allowsExternalPlayback = true
        }
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        service = appState.client.map(ChannelService.init(client:))
        nowPlaying.begin(client: appState.client)
        open()
        Task { [weak self] in
            guard let prefs = try? await self?.service?.playbackPrefs() else { return }
            self?.prefs = prefs
            self?.applyTracks()
        }
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    func stop() {
        guard !isStopped else { return }
        isStopped = true
        startTask?.cancel()
        refreshTask?.cancel()
        hideTask?.cancel()
        swapTask?.cancel()
        teardown(0)
        teardown(1)
        nowPlaying.end()
    }

    /// Starts the current channel again (Try Again).
    func retry() {
        open()
    }

    /// Channel up (+1) or down (-1), wrapping around the ends of the list.
    func zap(_ step: Int) {
        guard !isStopped, let next = Channel.neighbour(of: channel.id, in: zapList, step: step), next.id != channel.id else {
            showInfo()
            return
        }
        tune(to: next)
    }

    /// Switches to `target` (a mini-guide pick); the current channel just closes the guide.
    func tune(to target: Channel) {
        showsGuide = false
        showsControls = false
        openMenu = nil
        guard !isStopped, target.id != channel.id else {
            showInfo()
            return
        }
        channel = channels.first { $0.id == target.id } ?? target
        guide = nil
        open()
        Task { await refreshGuide() }
    }

    func showInfo() {
        showsInfo = true
        scheduleHide()
    }

    /// Opens the mini-guide; the banner makes room for it.
    func showGuide() {
        guard !isStopped else { return }
        hideTask?.cancel()
        showsInfo = false
        showsControls = false
        openMenu = nil
        showsGuide = true
    }

    /// Select on the picture: the banner with the options row, focus on it.
    func showControls() {
        guard !isStopped else { return }
        hideTask?.cancel()
        showsGuide = false
        showsInfo = true
        showsControls = true
    }

    /// Menu in the options row: an open list first, then the row itself.
    func closeControls() {
        if openMenu != nil {
            openMenu = nil
            return
        }
        showsControls = false
        scheduleHide()
    }

    // MARK: - Favourite

    var isFavorite: Bool {
        channels.first { $0.id == channel.id }?.favorite ?? channel.favorite
    }

    /// The star: shown at once, put back when the server says no. Zapping keeps going
    /// through the list the player was opened from (a channel just unstarred stays in place).
    func toggleFavorite() {
        guard let service else { return }
        let id = channel.id
        let favorite = !isFavorite
        setFavorite(favorite, id)
        Task { [weak self] in
            do {
                try await service.setFavorite(channelId: id, favorite)
            } catch {
                self?.setFavorite(!favorite, id)
                _ = self?.appState?.message(for: error)
            }
        }
    }

    private func setFavorite(_ favorite: Bool, _ id: Int) {
        if let index = channels.firstIndex(where: { $0.id == id }) { channels[index].favorite = favorite }
        if channel.id == id { channel.favorite = favorite }
    }

    // MARK: - Audio and subtitles

    /// The audio entries of the programme on air: its own list (labels from the API), else
    /// the stream's renditions.
    func audioEntries(at date: Date = Date()) -> [LiveTrack] {
        if let audio = onAir(at: date).now?.audio, !audio.isEmpty {
            return audio.filter { entry in audioOptions.isEmpty || option(for: entry, in: audioOptions) != nil }
        }
        return audioOptions.map { LiveTrack(slot: $0.name, name: $0.name, label: $0.name, lang: $0.language) }
    }

    func subtitleEntries(at date: Date = Date()) -> [LiveTrack] {
        if let subtitles = onAir(at: date).now?.subtitles {
            return subtitles.filter { entry in subtitleOptions.isEmpty || option(for: entry, in: subtitleOptions) != nil }
        }
        return subtitleOptions.map { LiveTrack(slot: $0.name, name: $0.name, label: $0.name, lang: $0.language) }
    }

    /// The slot that plays now.
    var audioSlot: String {
        selection.audio(for: onAir(at: Date()).now?.audio, prefs: prefs)
    }

    /// The subtitle slot shown now (nil: off).
    var subtitleSlot: String? {
        let program = onAir(at: Date()).now
        return selection.subtitle(for: program?.subtitles, audio: program?.audio, audioSlot: audioSlot, prefs: prefs)
    }

    /// The viewer's audio pick: sticks across programmes and channels for this session.
    func selectAudio(_ entry: LiveTrack) {
        selection.audioSlot = entry.slot
        openMenu = nil
        applyTracks(force: true)
    }

    /// The viewer's subtitle pick (nil: off).
    func selectSubtitle(_ entry: LiveTrack?) {
        selection.subtitleSlot = entry?.slot ?? ""
        subtitleText = nil
        openMenu = nil
        applyTracks(force: true)
    }

    /// Chooses the renditions of the item on screen (and of one loading underneath) for
    /// the programme on air; again whenever the programme changes.
    private func applyTracks(force: Bool = false) {
        let program = onAir(at: Date()).now
        guard force || program?.key != tracksProgram else { return }
        tracksProgram = program?.key
        for slot in [front, back] {
            guard let item = players[slot].currentItem, item.status == .readyToPlay else { continue }
            select(in: item)
        }
    }

    private func select(in item: AVPlayerItem) {
        let program = onAir(at: Date()).now
        let audioSlot = audioSlot
        let subtitleSlot = subtitleSlot
        let audioEntry = program?.audio?.first { $0.slot == audioSlot }
            ?? LiveTrack(slot: audioSlot, name: audioSlot, lang: LiveTrackSelection.slotLanguage(audioSlot))
        let subtitleEntry = subtitleSlot.map { slot in
            program?.subtitles?.first { $0.slot == slot } ?? LiveTrack(slot: slot, name: slot, lang: LiveTrackSelection.slotLanguage(slot))
        }
        Task { [weak self] in
            guard let self else { return }
            let asset = item.asset
            if let group = try? await asset.loadMediaSelectionGroup(for: .audible) {
                let options = group.options.map(StreamOption.init)
                if item === self.players[self.front].currentItem { self.audioOptions = options }
                if let index = self.optionIndex(for: audioEntry, in: options) {
                    item.select(group.options[index], in: group)
                }
            }
            if let group = try? await asset.loadMediaSelectionGroup(for: .legible) {
                let all = group.options.map(StreamOption.init)
                if item === self.players[self.front].currentItem { self.subtitleOptions = all.filter { !$0.isForcedOnly } }
                if let subtitleEntry, let index = self.optionIndex(for: subtitleEntry, in: all) {
                    item.select(group.options[index], in: group)
                } else {
                    item.select(nil, in: group)
                }
            }
        }
    }

    private func option(for entry: LiveTrack, in options: [StreamOption]) -> StreamOption? {
        optionIndex(for: entry, in: options).map { options[$0] }
    }

    /// The rendition of an entry: by its HLS NAME, else by the slot's language.
    private func optionIndex(for entry: LiveTrack, in options: [StreamOption]) -> Int? {
        if let index = options.firstIndex(where: { $0.name == entry.name && !$0.isForcedOnly }) { return index }
        let lang = entry.lang.isEmpty ? LiveTrackSelection.slotLanguage(entry.slot) : entry.lang
        guard !lang.isEmpty else { return nil }
        return options.firstIndex { $0.language.hasPrefix(lang) && !$0.isForcedOnly }
    }

    func hideGuide() {
        showsGuide = false
    }

    /// Play/Pause. Live goes on while paused, so playing again rejoins it at the live edge.
    func togglePause() {
        guard state == .playing else { return }
        if player.timeControlStatus == .paused {
            seekToLiveEdge()
            player.play()
        } else {
            player.pause()
            hideTask?.cancel()
            showsInfo = true
        }
    }

    /// The app went to the background: live cannot be caught up later, so stop the items.
    func suspend() {
        guard !isStopped else { return }
        startTask?.cancel()
        swapTask?.cancel()
        teardown(0)
        teardown(1)
        isHoldingFrame = false
    }

    func resumeFromBackground() {
        guard !isStopped, players.allSatisfy({ $0.currentItem == nil }) else { return }
        open()
    }

    // MARK: - Stream

    private var back: Int { 1 - front }

    /// Starts the current channel in the player underneath. A picture on screen is held:
    /// paused on its last frame until the new one is ready.
    private func open() {
        startTask?.cancel()
        swapTask?.cancel()
        teardown(back)
        tracksProgram = nil
        // The old channel's cue does not belong to the new one.
        subtitleText = nil
        if state == .playing, player.currentItem != nil, layers[front].isReadyForDisplay {
            player.pause()
            isHoldingFrame = true
        } else {
            teardown(front)
            isHoldingFrame = false
        }
        state = .connecting(isStarting: false)
        showInfo()
        nowPlaying.update(channel: channel, program: onAir(at: Date()).now)
        let id = channel.id
        startTask = Task { [weak self] in
            await self?.connect(channelId: id)
        }
    }

    private func connect(channelId: Int) async {
        guard let appState, let coordinator, let client = appState.client, let service else { return }
        do {
            let key = try await coordinator.mediaKeyStore(for: client).key()
            let url = try await service.tuneIn(channelId: channelId, mediaKey: key) { [weak self] in
                await self?.channelIsStarting(channelId)
            }
            guard !Task.isCancelled, channel.id == channelId, !isStopped else { return }
            load(url, into: back)
        } catch {
            guard !Task.isCancelled, channel.id == channelId, !isStopped else { return }
            fail(error)
        }
    }

    /// The server answered "starting": say so under the spinner.
    private func channelIsStarting(_ channelId: Int) {
        guard channel.id == channelId, case .connecting = state else { return }
        state = .connecting(isStarting: true)
    }

    private func load(_ url: URL, into slot: Int) {
        teardown(slot)
        let item = AVPlayerItem(url: url)
        // Join at the live edge; there is nothing to catch up on.
        item.automaticallyPreservesTimeOffsetFromLive = true
        let itemID = ObjectIdentifier(item)
        let player = players[slot]
        // The renditions are chosen here, from the profile's defaults and the viewer's picks.
        player.appliesMediaSelectionCriteriaAutomatically = false
        // Subtitles come out as text for the view to draw (above the banner when it is up).
        let receiver = LiveLegibleReceiver { [weak self] text in
            guard let self, self.front == slot, self.isItem(itemID, in: slot) else { return }
            if self.subtitleText != text { self.subtitleText = text }
        }
        item.add(receiver.output)
        legibleReceivers[slot] = receiver
        player.replaceCurrentItem(with: item)
        keyValueObservers[slot] = [
            item.observe(\.status, options: [.new]) { [weak self] item, _ in
                let status = item.status
                Task { @MainActor in
                    guard let self, self.isItem(itemID, in: slot) else { return }
                    switch status {
                    case .readyToPlay:
                        self.select(in: item)
                        self.itemIsReady(slot)
                    case .failed: self.fail(nil)
                    default: break
                    }
                }
            },
            layers[slot].observe(\.isReadyForDisplay, options: [.new]) { [weak self] layer, _ in
                let ready = layer.isReadyForDisplay
                Task { @MainActor in
                    guard ready, let self, self.isItem(itemID, in: slot) else { return }
                    self.swapIfReady(slot)
                }
            },
            player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
                let paused = player.timeControlStatus == .paused
                Task { @MainActor in
                    guard let self, self.front == slot, !self.isHoldingFrame, self.isPaused != paused else { return }
                    self.isPaused = paused
                }
            },
        ]
        notificationObservers[slot] = [
            NotificationCenter.default.addObserver(forName: AVPlayerItem.failedToPlayToEndTimeNotification, object: item, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.isItem(itemID, in: slot) else { return }
                    self.fail(nil)
                }
            },
        ]
        player.play()
    }

    private func isItem(_ id: ObjectIdentifier, in slot: Int) -> Bool {
        players[slot].currentItem.map(ObjectIdentifier.init) == id
    }

    /// The item can play: show it as soon as its first frame is up, or after a short grace
    /// period when the layer does not say so.
    private func itemIsReady(_ slot: Int) {
        swapIfReady(slot)
        guard slot != front || state != .playing else { return }
        swapTask?.cancel()
        swapTask = Task { [weak self] in
            try? await Task.sleep(for: Self.firstFrameGrace)
            guard !Task.isCancelled else { return }
            self?.swap(to: slot)
        }
    }

    private func swapIfReady(_ slot: Int) {
        guard players[slot].currentItem?.status == .readyToPlay, layers[slot].isReadyForDisplay else { return }
        swap(to: slot)
    }

    /// Puts `slot` on screen and lets the held picture go.
    private func swap(to slot: Int) {
        guard !isStopped, players[slot].currentItem != nil, state != .playing || slot != front else { return }
        swapTask?.cancel()
        let old = front
        front = slot
        if old != slot { teardown(old) }
        subtitleText = nil
        isHoldingFrame = false
        isPaused = players[slot].timeControlStatus == .paused
        state = .playing
        if let item = players[slot].currentItem { select(in: item) }
        nowPlaying.update(channel: channel, program: onAir(at: Date()).now, isPlaying: true)
        scheduleHide()
    }

    private func seekToLiveEdge() {
        guard let range = player.currentItem?.seekableTimeRanges.last?.timeRangeValue else { return }
        player.seek(to: range.end, toleranceBefore: .positiveInfinity, toleranceAfter: .zero)
    }

    private func teardown(_ slot: Int) {
        legibleReceivers[slot] = nil
        if slot == front { subtitleText = nil }
        keyValueObservers[slot].forEach { $0.invalidate() }
        keyValueObservers[slot] = []
        notificationObservers[slot].forEach(NotificationCenter.default.removeObserver)
        notificationObservers[slot] = []
        players[slot].pause()
        players[slot].replaceCurrentItem(with: nil)
    }

    /// Shows the server's message (busy, screen time, a gone channel), else "can't be shown".
    private func fail(_ error: Error?) {
        swapTask?.cancel()
        teardown(0)
        teardown(1)
        isHoldingFrame = false
        hideTask?.cancel()
        showsInfo = true
        showsGuide = false
        showsControls = false
        openMenu = nil
        var message = String(localized: "The channel can’t be shown", bundle: .localized)
        if let error {
            // nil: signed out (401).
            guard let text = appState?.message(for: error) else { return }
            message = text
        }
        state = .failed(message)
        nowPlaying.update(channel: channel, program: nil, isPlaying: false)
    }

    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: Self.infoDuration)
            guard !Task.isCancelled, let self, self.state == .playing, !self.isPaused, !self.showsControls else { return }
            self.showsInfo = false
        }
    }

    // MARK: - Guide

    private func refresh() async {
        await refreshGuide()
        guard let service, let list = try? await service.list() else { return }
        guard !isStopped, !list.channels.isEmpty else { return }
        channels = list.channels
        if let fresh = channels.first(where: { $0.id == channel.id }) {
            channel = fresh
        }
        applyTracks()
        nowPlaying.update(channel: channel, program: onAir(at: Date()).now, isPlaying: state == .playing && !isPaused)
    }

    private func refreshGuide() async {
        let id = channel.id
        guard let service, let fresh = try? await service.guide(channelId: id) else { return }
        guard !isStopped, channel.id == id else { return }
        guide = fresh
        applyTracks()
    }

    /// Called every few seconds by the view: a programme boundary picks the new
    /// programme's default tracks (unless the viewer picked one).
    func tick() {
        applyTracks()
    }
}

/// Hands the subtitle text of a live item to the model (the player draws none itself).
private final class LiveLegibleReceiver: NSObject, AVPlayerItemLegibleOutputPushDelegate {
    let output = AVPlayerItemLegibleOutput()
    private let onText: @MainActor (String?) -> Void

    init(onText: @escaping @MainActor (String?) -> Void) {
        self.onText = onText
        super.init()
        output.suppressesPlayerRendering = true
        output.setDelegate(self, queue: .main)
    }

    func legibleOutput(
        _ output: AVPlayerItemLegibleOutput, didOutputAttributedStrings strings: [NSAttributedString],
        nativeSampleBuffers nativeSamples: [Any], forItemTime itemTime: CMTime
    ) {
        let text = strings.map(\.string).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        MainActor.assumeIsolated { onText(text.isEmpty ? nil : text) }
    }
}

/// Which list the options row opened.
enum TrackMenuKind: Equatable {
    case audio
    case subtitles
}

/// A rendition of the stream on screen.
struct StreamOption: Equatable {
    /// The HLS `NAME`.
    let name: String
    /// The extended language tag ("ru", "en", "mul").
    let language: String
    let isForcedOnly: Bool

    init(_ option: AVMediaSelectionOption) {
        name = option.displayName
        language = option.extendedLanguageTag ?? option.locale?.language.languageCode?.identifier ?? ""
        isForcedOnly = option.hasMediaCharacteristic(.containsOnlyForcedSubtitles)
    }
}

/// The system's Now Playing for the live player: the programme, the channel and the live
/// flag (no scrubber, no time left), with the programme's backdrop as artwork. What was
/// there before (music, paused) comes back when the player closes.
@MainActor
private final class LiveNowPlaying {
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
        guard let client, let url = client.urls.image(path) else { return }
        let headers = client.authorizationHeaders(for: url)
        artworkTask = Task { [weak self] in
            guard let image = await ImagePipeline.shared.image(for: url, headers: headers, maxPixelSize: 800),
                  !Task.isCancelled, let self, self.artworkPath == path
            else { return }
            let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
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
