import AVFoundation
import AntresolKit
import Foundation
import MediaPlayer
import Observation
import UIKit

/// The live player of a channel («ТВ»): starts the channel's stream (waiting while the
/// server starts its encoder), plays it at the live edge and zaps to the neighbouring
/// channels by number or to a channel picked in the mini-guide. Live means no seeking, no
/// resume and no progress saving. The channel's guide (on now, next) and the channel list
/// are refreshed every 30 s.
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
    /// Every channel, by number: the order of channel up / down.
    private(set) var channels: [Channel]
    private(set) var guide: ChannelGuide?
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
    @ObservationIgnored private var isStopped = false

    /// How long the banner stays up after a change.
    private static let infoDuration: Duration = .seconds(5)
    /// How long a ready item may wait for its layer's first frame before it is shown anyway.
    private static let firstFrameGrace: Duration = .milliseconds(1500)

    init(request: PlaybackCoordinator.LiveRequest) {
        channel = request.channel
        var channels = request.channels.sorted { ($0.number, $0.id) < ($1.number, $1.id) }
        if !channels.contains(where: { $0.id == request.channel.id }) {
            channels.append(request.channel)
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

    /// The mini-guide's channels: the current section, starting at the current channel.
    var strip: ChannelStrip {
        ChannelStrip(current: channel, in: channels)
    }

    // MARK: - Lifecycle

    func start(appState: AppState, coordinator: PlaybackCoordinator) {
        self.appState = appState
        self.coordinator = coordinator
        for player in players {
            player.allowsExternalPlayback = true
        }
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        nowPlaying.begin(client: appState.client)
        open()
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
        guard !isStopped, let next = Channel.neighbour(of: channel.id, in: channels, step: step), next.id != channel.id else {
            showInfo()
            return
        }
        tune(to: next)
    }

    /// Switches to `target` (a mini-guide pick); the current channel just closes the guide.
    func tune(to target: Channel) {
        showsGuide = false
        guard !isStopped, target.id != channel.id else {
            showInfo()
            return
        }
        channel = channels.first { $0.id == target.id } ?? target
        guide = nil
        open()
        Task { await refreshGuide() }
    }

    func toggleInfo() {
        if showsInfo {
            hideTask?.cancel()
            showsInfo = false
        } else {
            showInfo()
        }
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
        showsGuide = true
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
        guard let appState, let coordinator, let client = appState.client else { return }
        do {
            let key = try await coordinator.mediaKeyStore(for: client).key()
            let url = try await client.startLiveChannel(id: channelId, mediaKey: key) { [weak self] in
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
        player.replaceCurrentItem(with: item)
        keyValueObservers[slot] = [
            item.observe(\.status, options: [.new]) { [weak self] item, _ in
                let status = item.status
                Task { @MainActor in
                    guard let self, self.isItem(itemID, in: slot) else { return }
                    switch status {
                    case .readyToPlay: self.itemIsReady(slot)
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
        isHoldingFrame = false
        isPaused = players[slot].timeControlStatus == .paused
        state = .playing
        appState?.profileKey.map { LastChannelStore().remember(channel.id, for: $0) }
        nowPlaying.update(channel: channel, program: onAir(at: Date()).now, isPlaying: true)
        scheduleHide()
    }

    private func seekToLiveEdge() {
        guard let range = player.currentItem?.seekableTimeRanges.last?.timeRangeValue else { return }
        player.seek(to: range.end, toleranceBefore: .positiveInfinity, toleranceAfter: .zero)
    }

    private func teardown(_ slot: Int) {
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
            guard !Task.isCancelled, let self, self.state == .playing, !self.isPaused else { return }
            self.showsInfo = false
        }
    }

    // MARK: - Guide

    private func refresh() async {
        await refreshGuide()
        guard let client = appState?.client, let list = try? await client.channels() else { return }
        guard !isStopped, !list.channels.isEmpty else { return }
        channels = list.channels.sorted { ($0.number, $0.id) < ($1.number, $1.id) }
        if let fresh = channels.first(where: { $0.id == channel.id }) {
            channel = fresh
        }
        nowPlaying.update(channel: channel, program: onAir(at: Date()).now, isPlaying: state == .playing && !isPaused)
    }

    private func refreshGuide() async {
        let id = channel.id
        guard let client = appState?.client, let fresh = try? await client.channelGuide(id: id) else { return }
        guard !isStopped, channel.id == id else { return }
        guide = fresh
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
