import AVFoundation
import AntresolKit
import Foundation
import Observation

/// The app-wide music player.
///
/// One `AVQueuePlayer` plays the current item with the next one queued behind it, so
/// songs follow each other without a gap. Stream URLs carry the media key, so the player
/// needs no headers. The source file is played as is when AVPlayer decodes it (AAC, MP3,
/// ALAC, FLAC); anything else is transcoded by the server, and such a stream is seeked by
/// reloading it with `t=` (§7.3).
///
/// Each song is scrobbled once (`POST /api/music/plays`). The lock-screen style Now
/// Playing info and the remote commands are kept in sync by `NowPlayingCenter`.
@MainActor
@Observable
final class AudioPlayer {
    /// A song in the queue.
    struct Item: Hashable, Sendable {
        let track: Track

        var title: String { track.title }
        var artist: String { track.artist }
        var album: String { track.album }
        var artwork: String { track.cover }
        var durationMs: Int { track.durationMs }
    }

    // MARK: Observable state

    private(set) var queue = PlayQueue<Item>()
    /// Playing, or waiting for data in order to play.
    private(set) var isPlaying = false
    private(set) var isBuffering = false
    /// Seconds into the current item.
    private(set) var position: Double = 0
    /// A short message about a failed song or a failed request, shown on Now Playing.
    private(set) var notice: String?
    /// Stars changed in this session, by track id (the queue keeps the tracks as loaded).
    private(set) var starredTracks: [Int: Bool] = [:]
    /// Incremented when Now Playing should come up (a new queue was started).
    private(set) var presentationRequests = 0

    var hasContent: Bool { !queue.isEmpty }
    var current: Item? { queue.current?.element }
    var currentTrack: Track? { current?.track }

    var durationSec: Double {
        Double(current?.durationMs ?? 0) / 1000
    }

    /// The signed-in profile's API client.
    var client: APIClient? { appState?.client }

    func isStarred(_ track: Track) -> Bool {
        starredTracks[track.id] ?? track.starred
    }

    // MARK: Engine

    @ObservationIgnored let player = AVQueuePlayer()
    @ObservationIgnored private weak var appState: AppState?
    @ObservationIgnored private var mediaKeys: MediaKeyStore?
    @ObservationIgnored private var mediaKey: String?
    /// The AVPlayerItems in the player, with what they play.
    @ObservationIgnored private var loaded: [ObjectIdentifier: LoadedItem] = [:]
    /// Whether a track id's stream is transcoded (learned from the response headers).
    @ObservationIgnored private var transcodedStreams: [Int: Bool] = [:]
    @ObservationIgnored private var scrobble: ScrobbleTracker?
    @ObservationIgnored private var pendingSeek: Double?
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var observers: [NSKeyValueObservation] = []
    @ObservationIgnored private var itemObservers: [ObjectIdentifier: [NSKeyValueObservation]] = [:]
    @ObservationIgnored private var noticeTask: Task<Void, Never>?
    /// Queues the rest of a paged song list behind the current queue (`play(tracks:startAt:continuing:)`).
    @ObservationIgnored private var queueFill: Task<Void, Never>?
    @ObservationIgnored private var nowPlaying: NowPlayingCenter!
    /// Items that failed in a row; playback stops instead of cycling a failing queue.
    @ObservationIgnored private var consecutiveFailures = 0

    private static let maxConsecutiveFailures = 3

    /// A player item and what it plays.
    private struct LoadedItem {
        let entryId: UUID
        /// The `t` the stream was requested with: the player's 0 is this item position.
        let offset: Double
        /// Known once the stream's headers were seen; a transcoded stream cannot seek.
        var transcoded: Bool
        /// The stream asked for FLAC as is; a failure is retried transcoded.
        let acceptsFLAC: Bool
    }

    init() {
        player.actionAtItemEnd = .advance
        observers = [
            player.observe(\.currentItem, options: [.new]) { [weak self] _, _ in
                Task { @MainActor in self?.currentItemChanged() }
            },
            player.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
                Task { @MainActor in self?.timeControlChanged() }
            },
        ]
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        nowPlaying = NowPlayingCenter(player: self)
    }

    /// Connects the player to the signed-in profile.
    func attach(to appState: AppState, mediaKeys: MediaKeyStore) {
        self.appState = appState
        self.mediaKeys = mediaKeys
    }

    // MARK: - Starting playback

    /// Plays songs from `index`, optionally shuffled (the chosen song still plays first
    /// unless `index` is nil, which shuffles everything).
    func play(tracks: [Track], startAt index: Int? = 0, shuffled: Bool = false) {
        startMusic(tracks, at: index, shuffled: shuffled)
    }

    /// Plays songs from `index` and then queues the rest of their list (e.g. the whole song
    /// library) page by page in the background, in list order. A page that keeps failing
    /// ends the queue there with a notice.
    func play(tracks: [Track], startAt index: Int, continuing rest: RemainingPages<Track>) {
        guard let starting = startMusic(tracks, at: index, shuffled: false), !rest.isEmpty else { return }
        queueFill = Task { [weak self] in
            await starting.value
            do {
                try await rest.run { batch in
                    guard let self, !Task.isCancelled, self.hasContent else { return false }
                    self.queue.extend(with: batch.map(Item.init(track:)))
                    self.refreshUpcoming()
                    return true
                }
            } catch {
                guard let self, !Task.isCancelled, !(error is CancellationError) else { return }
                // A 401 goes back to the profile picker instead.
                if self.appState?.message(for: error) != nil {
                    self.showNotice(String(localized: "Some songs couldn’t be added to the queue.", bundle: .localized))
                }
            }
        }
    }

    @discardableResult
    private func startMusic(_ tracks: [Track], at index: Int?, shuffled: Bool) -> Task<Void, Never>? {
        let items = tracks.map(Item.init(track:))
        guard !items.isEmpty else { return nil }
        queueFill?.cancel()
        var newQueue = PlayQueue(items, startAt: index ?? Int.random(in: 0..<items.count))
        newQueue.repeatMode = queue.repeatMode
        if shuffled { newQueue.setShuffle(true) }
        return Task { await start(newQueue) }
    }

    /// Adds songs right after the current one, or plays them when nothing is playing.
    func playNext(_ tracks: [Track]) {
        guard hasContent else { return play(tracks: tracks) }
        queue.insertNext(tracks.map(Item.init(track:)))
        refreshUpcoming()
        showNotice(String(localized: "Playing next", bundle: .localized))
    }

    /// Adds songs to the end of the queue, or plays them when nothing is playing.
    func addToQueue(_ tracks: [Track]) {
        guard hasContent else { return play(tracks: tracks) }
        queue.append(contentsOf: tracks.map(Item.init(track:)))
        refreshUpcoming()
        showNotice(String(localized: "Added to queue", bundle: .localized))
    }

    /// Removes an upcoming song from the queue.
    func remove(entry id: UUID) {
        queue.remove(entry: id)
        refreshUpcoming()
    }

    // MARK: - Transport

    func togglePlayPause() {
        isPlaying ? pause() : resume()
    }

    func resume() {
        guard hasContent else { return }
        consecutiveFailures = 0
        activateSession()
        if player.currentItem == nil, let index = queue.currentIndex {
            // The queue ran out; start the current item over.
            Task { await load(index: index, at: 0) }
            return
        }
        player.playImmediately(atRate: 1)
    }

    func pause() {
        player.pause()
    }

    /// Stops playback and empties the player.
    func stop() {
        queueFill?.cancel()
        player.pause()
        player.removeAllItems()
        loaded = [:]
        itemObservers = [:]
        queue = PlayQueue()
        position = 0
        scrobble = nil
        nowPlaying.clear()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// Stops playback and releases the player's observers and remote-command handlers.
    /// Call when the signed-in shell goes away; the player is not used afterwards.
    func shutdown() {
        stop()
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
        observers.forEach { $0.invalidate() }
        observers = []
        noticeTask?.cancel()
        nowPlaying.invalidate()
    }

    func next() {
        guard let index = queue.nextIndex else { return }
        Task { await load(index: index, at: 0) }
    }

    /// Previous song, or the start of this one after 3 s.
    func previous() {
        if position > 3 || queue.previousIndex == nil {
            seek(to: 0)
        } else if let index = queue.previousIndex {
            Task { await load(index: index, at: 0) }
        }
    }

    /// Jumps to an entry of the queue.
    func play(entry id: UUID) {
        guard let index = queue.items.firstIndex(where: { $0.id == id }) else { return }
        Task { await load(index: index, at: 0) }
    }

    func setShuffle(_ on: Bool) {
        queue.setShuffle(on)
        refreshUpcoming()
    }

    func cycleRepeat() {
        queue.repeatMode = queue.repeatMode.next
        refreshUpcoming()
    }

    func toggleStar(_ track: Track) {
        let starred = !isStarred(track)
        starredTracks[track.id] = starred
        guard let client = appState?.client else { return }
        Task {
            do {
                try await client.setStarred(itemId: track.id, starred)
            } catch {
                starredTracks[track.id] = !starred
                if let message = appState?.message(for: error) { showNotice(message) }
            }
        }
    }

    // MARK: - Seeking

    /// Seeks inside the current item: natively for original files, by reloading the
    /// stream at `t` for transcoded ones.
    func seek(to seconds: Double) {
        guard let playerItem = player.currentItem, let info = loaded[ObjectIdentifier(playerItem)] else { return }
        let target = max(0, seconds)
        position = target
        scrobble?.resetPosition()
        // A stream with nothing seekable once ready is a transcode the headers did not reveal.
        let transcoded = info.transcoded || (playerItem.status == .readyToPlay && playerItem.seekableTimeRanges.isEmpty)
        if !transcoded {
            if playerItem.status == .readyToPlay {
                player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
            } else {
                pendingSeek = target
            }
            nowPlaying.update()
            return
        }
        guard let index = queue.currentIndex else { return }
        Task { await load(index: index, at: target) }
    }

    // MARK: - Loading

    private func start(_ newQueue: PlayQueue<Item>) async {
        consecutiveFailures = 0
        queue = newQueue
        notice = nil
        presentationRequests += 1
        guard let index = queue.currentIndex else { return }
        await load(index: index, at: 0)
    }

    /// Makes the queue entry at `index` the current item, starting at `offset` seconds.
    private func load(index: Int, at offset: Double) async {
        guard let entry = queue.move(to: index) else { return }
        // Without any key the stream would only answer 401.
        guard await refreshMediaKey() || mediaKey != nil else { return }
        let isTranscoded = await transcoding(entry.element)
        guard queue.current?.id == entry.id else { return }
        guard let playerItem = makePlayerItem(for: entry, offset: offset, transcoded: isTranscoded) else { return }
        player.removeAllItems()
        loaded = [:]
        itemObservers = [:]
        register(playerItem, entry: entry, offset: isTranscoded ? offset : 0, transcoded: isTranscoded, acceptsFLAC: !isTranscoded)
        player.insert(playerItem, after: nil)
        pendingSeek = (!isTranscoded && offset > 0) ? offset : nil
        position = offset
        startedItem(entry)
        activateSession()
        player.playImmediately(atRate: 1)
        refreshUpcoming()
    }

    /// Queues the item that follows the current one, replacing a stale one.
    private func refreshUpcoming() {
        guard let currentItem = player.currentItem else { return }
        let wanted = queue.indexAfterCurrentEnds.map { queue.items[$0] }
        let queued = player.items().drop { $0 !== currentItem }.dropFirst()
        if let first = queued.first, let info = loaded[ObjectIdentifier(first)], info.entryId == wanted?.id, queued.count == 1 {
            return
        }
        for item in queued {
            player.remove(item)
            forget(item)
        }
        guard let wanted, let next = makePlayerItem(for: wanted, offset: 0, transcoded: false) else { return }
        let known = knownTranscoding(wanted.element)
        register(next, entry: wanted, offset: 0, transcoded: known ?? false, acceptsFLAC: known != true)
        player.insert(next, after: currentItem)
        if known == nil {
            // Learn it before anyone seeks in that item.
            let id = ObjectIdentifier(next)
            Task {
                let transcoded = await transcoding(wanted.element)
                loaded[id]?.transcoded = transcoded
            }
        }
    }

    private func makePlayerItem(for entry: PlayQueue<Item>.Entry, offset: Double, transcoded: Bool, forceTranscode: Bool = false) -> AVPlayerItem? {
        guard let url = streamURL(for: entry.element, offset: transcoded ? offset : 0, forceTranscode: forceTranscode) else { return nil }
        return AVPlayerItem(url: url)
    }

    private func streamURL(for item: Item, offset: Double, forceTranscode: Bool) -> URL? {
        guard let urls = appState?.client?.urls else { return nil }
        let accept = forceTranscode ? AudioCodec.apple.filter { $0 != .flac } : AudioCodec.apple
        let format: AudioTranscodeFormat? = forceTranscode ? .aac : nil
        let start = offset > 0 ? offset : nil
        return urls.trackStream(trackId: item.track.id, accept: accept, format: format, startSec: start, mediaKey: mediaKey)
    }

    /// Whether the server transcodes this song for our `accept` list, from the stream's
    /// response headers (a transcode has `X-Vault-Transcode: 1` and `Accept-Ranges: none`).
    /// Cached per song.
    private func transcoding(_ item: Item) async -> Bool {
        if let known = knownTranscoding(item) { return known }
        guard let url = streamURL(for: item, offset: 0, forceTranscode: false) else { return false }
        let key = item.track.id
        var request = URLRequest(url: url)
        request.setValue("bytes=0-1", forHTTPHeaderField: "Range")
        do {
            // Only the headers are needed; dropping the byte stream cancels the download.
            let (_, response) = try await URLSession.shared.bytes(for: request)
            let http = response as? HTTPURLResponse
            let transcoded = http?.value(forHTTPHeaderField: "X-Vault-Transcode") == "1"
                || http?.value(forHTTPHeaderField: "Accept-Ranges") == "none"
            transcodedStreams[key] = transcoded
            return transcoded
        } catch {
            return false
        }
    }

    private func knownTranscoding(_ item: Item) -> Bool? {
        transcodedStreams[item.track.id]
    }

    private func register(_ playerItem: AVPlayerItem, entry: PlayQueue<Item>.Entry, offset: Double, transcoded: Bool, acceptsFLAC: Bool) {
        let id = ObjectIdentifier(playerItem)
        loaded[id] = LoadedItem(entryId: entry.id, offset: offset, transcoded: transcoded, acceptsFLAC: acceptsFLAC)
        itemObservers[id] = [
            playerItem.observe(\.status, options: [.new]) { [weak self] item, _ in
                Task { @MainActor in self?.statusChanged(item) }
            },
        ]
    }

    private func forget(_ playerItem: AVPlayerItem) {
        let id = ObjectIdentifier(playerItem)
        loaded[id] = nil
        itemObservers[id] = nil
    }

    /// Fetches a fresh media key when needed; false when that failed.
    @discardableResult
    private func refreshMediaKey() async -> Bool {
        guard let mediaKeys else { return false }
        do {
            mediaKey = try await mediaKeys.key()
            return true
        } catch {
            if let message = appState?.message(for: error) { showNotice(message) }
            return false
        }
    }

    // MARK: - Player events

    private func currentItemChanged() {
        guard let playerItem = player.currentItem else {
            // The end of the queue (or a stop): nothing more to play.
            if hasContent { finishedQueue() }
            return
        }
        guard let info = loaded[ObjectIdentifier(playerItem)] else { return }
        // Forget items the queue player already let go of.
        let alive = Set(player.items().map(ObjectIdentifier.init))
        for id in loaded.keys where !alive.contains(id) {
            loaded[id] = nil
            itemObservers[id] = nil
        }
        if queue.current?.id != info.entryId, let entry = queue.move(toEntry: info.entryId) {
            position = info.offset
            startedItem(entry)
        } else if queue.repeatMode == .one, info.offset == 0, pendingSeek == nil {
            // The same song again (repeat one).
            position = 0
            if let entry = queue.current { startedItem(entry) }
        }
        Task {
            await refreshMediaKey()
            refreshUpcoming()
        }
    }

    private func statusChanged(_ playerItem: AVPlayerItem) {
        let id = ObjectIdentifier(playerItem)
        guard let info = loaded[id] else { return }
        switch playerItem.status {
        case .readyToPlay:
            if playerItem === player.currentItem { consecutiveFailures = 0 }
            if playerItem === player.currentItem, let seek = pendingSeek {
                pendingSeek = nil
                player.seek(to: CMTime(seconds: seek, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
            }
        case .failed:
            itemFailed(playerItem, info: info)
        default:
            break
        }
    }

    /// A stream AVPlayer could not open: retry an original FLAC once as transcoded AAC,
    /// otherwise skip to the next song. After a few failures in a row (server down, media
    /// key refused) playback stops rather than cycling through the queue.
    private func itemFailed(_ playerItem: AVPlayerItem, info: LoadedItem) {
        guard let entry = queue.items.first(where: { $0.id == info.entryId }) else { return }
        let isCurrent = playerItem === player.currentItem
        if info.acceptsFLAC, let retry = makePlayerItem(for: entry, offset: isCurrent ? position : 0, transcoded: true, forceTranscode: true) {
            transcodedStreams[entry.element.track.id] = true
            let offset = isCurrent ? position : 0
            register(retry, entry: entry, offset: offset, transcoded: true, acceptsFLAC: false)
            player.insert(retry, after: playerItem)
            player.remove(playerItem)
            forget(playerItem)
            if isCurrent { player.playImmediately(atRate: 1) }
            return
        }
        player.remove(playerItem)
        forget(playerItem)
        guard isCurrent else { return }
        consecutiveFailures += 1
        if consecutiveFailures >= min(queue.count, Self.maxConsecutiveFailures) {
            player.pause()
            showNotice(String(localized: "Playback stopped because the server isn’t sending audio. Try again later.", bundle: .localized))
            return
        }
        showNotice(String(localized: "Couldn’t play “\(entry.element.title)”.", bundle: .localized))
        if let next = queue.nextIndex, next != queue.currentIndex {
            Task { await load(index: next, at: 0) }
        }
    }

    private func finishedQueue() {
        isPlaying = false
        position = durationSec
        nowPlaying.update()
    }

    private func timeControlChanged() {
        let playing = player.timeControlStatus != .paused
        let buffering = player.timeControlStatus == .waitingToPlayAtSpecifiedRate
        if isPlaying != playing { isPlaying = playing }
        if isBuffering != buffering { isBuffering = buffering }
        if !playing { scrobble?.resetPosition() }
        nowPlaying.update()
    }

    private func tick() {
        guard let playerItem = player.currentItem, let info = loaded[ObjectIdentifier(playerItem)], pendingSeek == nil else { return }
        let time = player.currentTime().seconds
        guard time.isFinite else { return }
        position = info.offset + time
        if isPlaying, var tracker = scrobble {
            if tracker.advance(to: position) {
                recordPlay(trackId: tracker.trackId)
            }
            scrobble = tracker
        }
    }

    /// Bookkeeping when an item becomes current.
    private func startedItem(_ entry: PlayQueue<Item>.Entry) {
        let track = entry.element.track
        scrobble = ScrobbleTracker(trackId: track.id, durationMs: track.durationMs)
        nowPlaying.update()
    }

    private func recordPlay(trackId: Int) {
        guard let client = appState?.client else { return }
        Task { try? await client.recordPlay(trackId: trackId, at: Date()) }
    }

    // MARK: - Helpers

    private func activateSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default)
        try? session.setActive(true)
    }

    private func showNotice(_ message: String) {
        noticeTask?.cancel()
        notice = message
        noticeTask = Task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled else { return }
            notice = nil
        }
    }
}
