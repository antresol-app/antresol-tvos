import AVFoundation
import AntresolKit
import Foundation
import Observation

/// The live player of a channel («ТВ»): starts the channel's stream (waiting while the
/// server starts its encoder), plays it at the live edge and zaps to the neighbouring
/// channels by number. Live means no seeking, no resume and no progress saving. The
/// channel's guide (on now, next) and the channel list are refreshed every 30 s.
@MainActor
@Observable
final class LivePlayerModel {
    enum State: Equatable {
        /// Asking the server for the stream; `isStarting` once it said the channel is starting.
        case connecting(isStarting: Bool)
        case playing
        case failed(String)
    }

    private(set) var state: State = .connecting(isStarting: false)
    private(set) var channel: Channel
    /// Every channel, by number: the order of channel up / down.
    private(set) var channels: [Channel]
    private(set) var guide: ChannelGuide?
    /// The channel info panel (logo, what is on, next) is up.
    private(set) var showsInfo = true
    private(set) var isPaused = false

    let player = AVPlayer()

    private weak var appState: AppState?
    private weak var coordinator: PlaybackCoordinator?
    private var startTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var hideTask: Task<Void, Never>?
    private var keyValueObservers: [NSKeyValueObservation] = []
    private var notificationObservers: [NSObjectProtocol] = []
    private var isStopped = false

    /// How long the info panel stays up after a change.
    private static let infoDuration: Duration = .seconds(6)

    init(request: PlaybackCoordinator.LiveRequest) {
        channel = request.channel
        channels = request.channels.sorted { ($0.number, $0.id) < ($1.number, $1.id) }
        if !channels.contains(where: { $0.id == request.channel.id }) {
            channels.append(request.channel)
        }
    }

    /// What is on now and next: from the guide, else from the channel list.
    func onAir(at date: Date) -> (now: ChannelProgram?, next: ChannelProgram?) {
        if let guide, guide.channel.id == channel.id, !guide.programs.isEmpty {
            return guide.onAir(at: date)
        }
        let now = channel.program(at: date)
        let next = channel.next.flatMap { $0 == now ? nil : $0 }
        return (now, next)
    }

    // MARK: - Lifecycle

    func start(appState: AppState, coordinator: PlaybackCoordinator) {
        self.appState = appState
        self.coordinator = coordinator
        player.allowsExternalPlayback = true
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
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
        teardownItem()
        player.pause()
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
        channel = next
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

    /// The app went to the background: live cannot be caught up later, so stop the item.
    func suspend() {
        guard !isStopped else { return }
        startTask?.cancel()
        teardownItem()
    }

    func resumeFromBackground() {
        guard !isStopped, player.currentItem == nil else { return }
        open()
    }

    // MARK: - Stream

    private func open() {
        startTask?.cancel()
        teardownItem()
        state = .connecting(isStarting: false)
        showInfo()
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
            load(url)
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

    private func load(_ url: URL) {
        teardownItem()
        let item = AVPlayerItem(url: url)
        // Join at the live edge; there is nothing to catch up on.
        item.automaticallyPreservesTimeOffsetFromLive = true
        let itemID = ObjectIdentifier(item)
        player.replaceCurrentItem(with: item)
        keyValueObservers = [
            item.observe(\.status, options: [.new]) { [weak self] item, _ in
                let status = item.status
                Task { @MainActor in
                    guard let self, self.isCurrentItem(itemID) else { return }
                    switch status {
                    case .readyToPlay:
                        self.state = .playing
                        self.scheduleHide()
                    case .failed: self.fail(nil)
                    default: break
                    }
                }
            },
            player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
                let paused = player.timeControlStatus == .paused
                Task { @MainActor in
                    guard let self, self.isPaused != paused else { return }
                    self.isPaused = paused
                }
            },
        ]
        notificationObservers = [
            NotificationCenter.default.addObserver(forName: AVPlayerItem.failedToPlayToEndTimeNotification, object: item, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.isCurrentItem(itemID) else { return }
                    self.fail(nil)
                }
            },
        ]
        player.play()
    }

    private func isCurrentItem(_ id: ObjectIdentifier) -> Bool {
        player.currentItem.map(ObjectIdentifier.init) == id
    }

    private func seekToLiveEdge() {
        guard let range = player.currentItem?.seekableTimeRanges.last?.timeRangeValue else { return }
        player.seek(to: range.end, toleranceBefore: .positiveInfinity, toleranceAfter: .zero)
    }

    private func teardownItem() {
        keyValueObservers.forEach { $0.invalidate() }
        keyValueObservers = []
        notificationObservers.forEach(NotificationCenter.default.removeObserver)
        notificationObservers = []
        player.replaceCurrentItem(with: nil)
    }

    /// Shows the server's message (busy, screen time, a gone channel), else "can't be shown".
    private func fail(_ error: Error?) {
        teardownItem()
        hideTask?.cancel()
        showsInfo = true
        var message = String(localized: "The channel can’t be shown", bundle: .localized)
        if let error {
            // nil: signed out (401).
            guard let text = appState?.message(for: error) else { return }
            message = text
        }
        state = .failed(message)
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
    }

    private func refreshGuide() async {
        let id = channel.id
        guard let client = appState?.client, let fresh = try? await client.channelGuide(id: id) else { return }
        guard !isStopped, channel.id == id else { return }
        guide = fresh
    }
}
