import AVFoundation
import AntresolKit
import Foundation
import MediaPlayer
import Observation
import os
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
/// An external channel (an admin's M3U / Xtream source) plays the provider's URL
/// directly, with the User-Agent / Referer its playlist asked for (AVURLAsset options);
/// only the server's redirect form (`/api/channels/live/ext/…`) carries the media key. A
/// source that fails, ends at once or does not start in 20 s gives way to the next fallback;
/// when none plays, «This channel won’t open right now» once (no retry loop; Try Again and
/// Up / Down are the viewer's). Its audio and subtitles are the stream's own options; the
/// pick is kept per channel on this device (`ExternalTrackMemory`), never sent.
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
    /// The viewer's picks of this session on own channels (never sent anywhere).
    private(set) var selection = LiveTrackSelection()
    /// The viewer's picks on the external channel on screen (kept per channel on the device).
    private(set) var externalSelection = LiveTrackSelection()
    /// The picks in force for the channel on screen.
    private var activeSelection: LiveTrackSelection { channel.external ? externalSelection : selection }
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
    /// Per player: the renditions of its master playlist (read while the channel starts),
    /// which tell AVFoundation's options apart.
    @ObservationIgnored private var renditions = [LiveRenditions(), LiveRenditions()]

    /// An external channel: the sources this platform plays, in order, and the one tried.
    @ObservationIgnored private(set) var externalSources: [StreamSource] = []
    @ObservationIgnored private(set) var externalAttempt = 0
    @ObservationIgnored private var externalPlayingSince: Date?
    @ObservationIgnored private var externalWatch: Task<Void, Never>?
    @ObservationIgnored private let trackMemory = ExternalTrackMemory()
    /// How long an external source may take to start before the next one is tried.
    private static let externalStartTimeout: Duration = .seconds(20)

    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Antresol", category: "live")

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
        externalSelection = ExternalTrackMemory().selection(for: request.channel.id)
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
        externalWatch?.cancel()
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
        externalSelection = trackMemory.selection(for: channel.id)
        audioOptions = []
        subtitleOptions = []
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
        if channel.external {
            return ExternalTracks.entries(options: audioOptions.map { ($0.name, $0.language) }, renditions: renditions[front].audio)
        }
        if let audio = onAir(at: date).now?.audio, !audio.isEmpty {
            return audio.filter { entry in audioOptions.isEmpty || optionIndex(for: entry, in: audioOptions, renditions: renditions[front].audio) != nil }
        }
        return audioOptions.map { LiveTrack(name: $0.name, label: $0.name, lang: $0.language) }
    }

    func subtitleEntries(at date: Date = Date()) -> [LiveTrack] {
        if channel.external {
            return ExternalTracks.entries(options: subtitleOptions.map { ($0.name, $0.language) }, renditions: renditions[front].subtitles)
        }
        if let subtitles = onAir(at: date).now?.subtitles {
            return subtitles.filter { entry in
                subtitleOptions.isEmpty || optionIndex(for: entry, in: subtitleOptions, renditions: renditions[front].subtitles) != nil
            }
        }
        return subtitleOptions.map { LiveTrack(name: $0.name, label: $0.name, lang: $0.language) }
    }

    /// The voice that plays now (nil: none known).
    var audioTrack: LiveTrack? {
        activeSelection.audio(in: audioEntries(), prefs: prefs)
    }

    /// The subtitles shown now (nil: off).
    var subtitleTrack: LiveTrack? {
        activeSelection.subtitle(in: subtitleEntries(), audio: audioTrack, prefs: prefs)
    }

    /// The viewer's audio pick: sticks by name across programmes and channels for this session.
    func selectAudio(_ entry: LiveTrack) {
        if channel.external {
            externalSelection.audio = .init(entry)
            trackMemory.save(externalSelection, for: channel.id)
        } else {
            selection.audio = .init(entry)
        }
        openMenu = nil
        applyTracks(force: true)
    }

    /// The viewer's subtitle pick (nil: off).
    func selectSubtitle(_ entry: LiveTrack?) {
        if channel.external {
            externalSelection.subtitle = .some(entry.map(LiveTrackSelection.Pick.init))
            trackMemory.save(externalSelection, for: channel.id)
        } else {
            selection.subtitle = .some(entry.map(LiveTrackSelection.Pick.init))
        }
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
            select(in: item, slot: slot)
        }
    }

    private func select(in item: AVPlayerItem, slot: Int) {
        let master = renditions[slot]
        Task { [weak self] in
            guard let self else { return }
            let asset = item.asset
            var audioLine = "-", audioNames: [String] = []
            if let group = try? await asset.loadMediaSelectionGroup(for: .audible) {
                let options = await StreamOption.describe(group.options)
                if item === self.players[self.front].currentItem { self.audioOptions = options }
                // the choice once the options are known (a programme without its own list uses them)
                if let entry = self.audioTrack, let index = self.optionIndex(for: entry, in: options, renditions: master.audio),
                   group.options.indices.contains(index) {
                    item.select(group.options[index], in: group)
                }
                audioNames = options.map(\.name)
                if let playing = item.currentMediaSelection.selectedMediaOption(in: group), let index = group.options.firstIndex(of: playing) {
                    let name = LiveRenditions.name(ofOption: index, options: options.map { ($0.name, $0.language) }, renditions: master.audio)
                    audioLine = "\(name ?? "?") [option \(index) «\(playing.displayName)» \(options[index].language)]"
                }
            }
            var subtitleLine = "off"
            if let group = try? await asset.loadMediaSelectionGroup(for: .legible) {
                let all = await StreamOption.describe(group.options)
                if item === self.players[self.front].currentItem { self.subtitleOptions = all.filter { !$0.isForcedOnly } }
                if let entry = self.subtitleTrack, let index = self.optionIndex(for: entry, in: all, renditions: master.subtitles),
                   group.options.indices.contains(index) {
                    item.select(group.options[index], in: group)
                    subtitleLine = "\(entry.name) [option \(index)]"
                } else {
                    item.select(nil, in: group)
                }
            }
            Self.log.info("""
                live tracks: audio \(self.audioTrack?.name ?? "-", privacy: .public) → \(audioLine, privacy: .public) \
                of \(audioNames, privacy: .public) / master \(master.audio.map(\.name), privacy: .public); \
                subtitles \(subtitleLine, privacy: .public) / master \(master.subtitles.map(\.name), privacy: .public)
                """)
        }
    }

    /// The option of an entry (`LiveRenditions`): aligned with the master's rendition of
    /// that NAME (by title, else the master's order checked by language, else the order
    /// within the language), else an option titled so, else the first of its language.
    private func optionIndex(for entry: LiveTrack, in options: [StreamOption], renditions: [HLSRendition]) -> Int? {
        let usable = options.enumerated().filter { !$0.element.isForcedOnly }
        if channel.external {
            // the entries are the usable options in order: `o<i>` is the i-th of them
            guard let i = ExternalTracks.index(of: entry), usable.indices.contains(i) else { return nil }
            return usable[i].offset
        }
        let index = LiveRenditions.option(named: entry.name, lang: entry.lang,
                                          options: usable.map { ($0.element.name, $0.element.language) }, renditions: renditions)
        return index.map { usable[$0].offset }
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
        externalWatch?.cancel()
        let id = channel.id
        if channel.external {
            openExternal()
            return
        }
        startTask = Task { [weak self] in
            await self?.connect(channelId: id)
        }
    }

    // MARK: - External channel

    /// The sources this platform plays, from the primary; the channel becomes the last one.
    private func openExternal() {
        let id = channel.id
        externalSources = channel.stream?.playable(on: ChannelStream.tvOSTags) ?? []
        externalAttempt = 0
        if let service { Task { await service.setLastChannel(id) } }
        guard !externalSources.isEmpty else {
            failExternal(channel.stream == nil
                ? String(localized: "This channel won’t open right now", bundle: .localized)
                : String(localized: "This channel doesn’t play on Apple TV", bundle: .localized))
            return
        }
        tryExternal()
    }

    /// Loads source `externalAttempt` into the player underneath: the provider's URL as
    /// given with its headers, the server's redirect with the media key.
    private func tryExternal() {
        let id = channel.id, attempt = externalAttempt, source = externalSources[attempt], slot = back
        state = .connecting(isStarting: false)
        startTask?.cancel()
        startTask = Task { [weak self] in
            guard let self, let appState = self.appState, let client = appState.client else { return }
            var key: String?
            if source.isServerPath, let coordinator = self.coordinator {
                key = try? await coordinator.mediaKeyStore(for: client).key()
            }
            guard !Task.isCancelled, self.channel.id == id, !self.isStopped else { return }
            guard let url = client.urls.externalStream(source, mediaKey: key) else {
                self.externalFailed()
                return
            }
            // never the URL: a provider's may carry credentials
            Self.log.info("live: external source \(attempt + 1) of \(self.externalSources.count), headers \(source.headers.keys.sorted(), privacy: .public)")
            self.renditions[slot] = LiveRenditions()
            self.load(url, headers: source.headers, into: slot)
            self.watchExternalStart(id: id, attempt: attempt)
            // the master's renditions name the stream's options (best effort)
            if let master = await Self.fetchMaster(url, headers: source.headers),
               !Task.isCancelled, self.channel.id == id, self.externalAttempt == attempt, !self.isStopped {
                self.renditions[slot] = LiveRenditions(master: master)
                self.applyTracks(force: true)
            }
        }
    }

    private func watchExternalStart(id: Int, attempt: Int) {
        externalWatch?.cancel()
        externalWatch = Task { [weak self] in
            try? await Task.sleep(for: Self.externalStartTimeout)
            guard !Task.isCancelled, let self, self.channel.id == id, self.externalAttempt == attempt,
                  case .connecting = self.state else { return }
            Self.log.error("live: external source \(attempt + 1) did not start in time")
            self.externalFailed()
        }
    }

    /// The stream's master playlist with the source's headers, nil when it is not one.
    nonisolated static func fetchMaster(_ url: URL, headers: [String: String]) async -> Data? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.httpShouldHandleCookies = false
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              data.count < 2_000_000, data.starts(with: Data("#EXTM3U".utf8)) else { return nil }
        return data
    }

    /// The source failed (an error, no start in time, an end right away): the next
    /// fallback, else the message, once.
    private func externalFailed() {
        guard !isStopped, channel.external else { return }
        externalWatch?.cancel()
        if externalAttempt + 1 < externalSources.count {
            externalAttempt += 1
            swapTask?.cancel()
            teardown(0)
            teardown(1)
            isHoldingFrame = false
            tryExternal()
        } else {
            failExternal(String(localized: "This channel won’t open right now", bundle: .localized))
        }
    }

    private func failExternal(_ message: String) {
        externalWatch?.cancel()
        startTask?.cancel()
        swapTask?.cancel()
        teardown(0)
        teardown(1)
        isHoldingFrame = false
        hideTask?.cancel()
        showsInfo = true
        showsGuide = false
        showsControls = false
        openMenu = nil
        state = .failed(message)
        nowPlaying.update(channel: channel, program: nil, isPlaying: false)
    }

    /// An item failed or stopped: an external channel tries its next source.
    private func itemFailed() {
        if channel.external { externalFailed() } else { fail(nil) }
    }

    /// An external stream played to its end (a provider's VOD loop, a dropped live):
    /// again from the start when it played a while, else it is a broken source.
    private func itemEnded() {
        guard channel.external, !isStopped else { return }
        if Date().timeIntervalSince(externalPlayingSince ?? .distantFuture) >= 10 {
            open()
        } else {
            externalFailed()
        }
    }

    private func connect(channelId: Int) async {
        guard let appState, let coordinator, let client = appState.client, let service else { return }
        do {
            let key = try await coordinator.mediaKeyStore(for: client).key()
            let stream = try await service.tuneInStream(channelId: channelId, mediaKey: key) { [weak self] in
                await self?.channelIsStarting(channelId)
            }
            guard !Task.isCancelled, channel.id == channelId, !isStopped else { return }
            renditions[back] = stream.renditions
            load(stream.url, into: back)
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

    /// The AVURLAsset options for an external stream's headers: User-Agent by its public
    /// key, every header (Referer too) by "AVURLAssetHTTPHeaderFieldsKey" (honoured by
    /// AVFoundation on tvOS for the playlist, its variants and segments).
    nonisolated static func assetOptions(headers: [String: String]) -> [String: Any] {
        guard !headers.isEmpty else { return [:] }
        var options: [String: Any] = ["AVURLAssetHTTPHeaderFieldsKey": headers]
        if let ua = headers["User-Agent"] { options[AVURLAssetHTTPUserAgentKey] = ua }
        return options
    }

    private func load(_ url: URL, headers: [String: String] = [:], into slot: Int) {
        teardown(slot)
        let item = headers.isEmpty ? AVPlayerItem(url: url)
            : AVPlayerItem(asset: AVURLAsset(url: url, options: Self.assetOptions(headers: headers)))
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
                        self.select(in: item, slot: slot)
                        self.itemIsReady(slot)
                    case .failed: self.itemFailed()
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
                    self.itemFailed()
                }
            },
            NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.isItem(itemID, in: slot) else { return }
                    self.itemEnded()
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
        if channel.external {
            externalWatch?.cancel()
            externalPlayingSince = Date()
        }
        if let item = players[slot].currentItem { select(in: item, slot: slot) }
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
    /// The HLS `NAME` when the asset keeps it (the option's title metadata), else
    /// AVFoundation's display name (made from the language: «Английский» for "English").
    let name: String
    /// The extended language tag ("ru", "en", "mul").
    let language: String
    let isForcedOnly: Bool

    init(_ option: AVMediaSelectionOption, title: String? = nil) {
        name = title ?? option.displayName
        language = option.extendedLanguageTag ?? option.locale?.language.languageCode?.identifier ?? ""
        isForcedOnly = option.hasMediaCharacteristic(.containsOnlyForcedSubtitles)
    }

    /// The options with their titles loaded.
    static func describe(_ options: [AVMediaSelectionOption]) async -> [StreamOption] {
        var out: [StreamOption] = []
        for option in options {
            let titles = AVMetadataItem.metadataItems(from: option.commonMetadata, filteredByIdentifier: .commonIdentifierTitle)
            let title = try? await titles.first?.load(.stringValue)
            out.append(StreamOption(option, title: title ?? nil))
        }
        return out
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
