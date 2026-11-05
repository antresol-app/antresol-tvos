import AVFoundation
import AntresolKit
import Foundation
import Observation
import UIKit

/// The app-wide audio player for music and audiobooks.
///
/// One `AVQueuePlayer` plays the current item with the next one queued behind it, so
/// songs follow each other without a gap. Stream URLs carry the media key, so the player
/// needs no headers. The source file is played as is when AVPlayer decodes it (AAC, MP3,
/// ALAC, FLAC); anything else is transcoded by the server, and such a stream is seeked by
/// reloading it with `t=` (§7.3).
///
/// Music scrobbles each song once (`POST /api/music/plays`). Audiobooks play their parts as
/// one continuous book and save the whole-book position every 10 s, on pause and when the
/// app goes to the background. The lock-screen style Now Playing info and the remote
/// commands are kept in sync by `NowPlayingCenter`.
@MainActor
@Observable
final class AudioPlayer {
    /// What is loaded.
    enum Content: Equatable {
        case music
        case audiobook(BookDetail)
    }

    /// Something the queue plays: a song, or one part of an audiobook.
    struct Item: Hashable, Sendable {
        enum Source: Hashable, Sendable {
            case track(Track)
            case audiobookPart(fileId: Int, index: Int)
        }

        let source: Source
        let title: String
        let artist: String
        let album: String
        let artwork: String
        let durationMs: Int

        var track: Track? {
            if case .track(let track) = source { return track }
            return nil
        }

        init(track: Track) {
            source = .track(track)
            title = track.title
            artist = track.artist
            album = track.album
            artwork = track.cover
            durationMs = track.durationMs
        }

        init(book: BookDetail, partIndex: Int) {
            let file = book.files[partIndex]
            source = .audiobookPart(fileId: file.id, index: partIndex)
            title = book.card.title
            artist = book.authors.joined(separator: ", ")
            album = book.files.count > 1 ? String(localized: "Part \(partIndex + 1) of \(book.files.count)", bundle: .localized) : ""
            artwork = book.card.poster
            durationMs = file.durationMs
        }
    }

    /// Sleep timer choices for audiobooks.
    enum SleepTimer: Hashable {
        case minutes(Int)
        case endOfChapter

        static let choices: [SleepTimer] = [.minutes(5), .minutes(15), .minutes(30), .minutes(45), .minutes(60), .endOfChapter]
    }

    /// Playback speeds offered for audiobooks (0.75–3.0 in steps of 0.25, like the web app).
    static let speeds: [Float] = stride(from: 0.75, through: 3.0, by: 0.25).map { Float($0) }

    // MARK: Observable state

    private(set) var content: Content?
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
    /// Audiobook speed.
    private(set) var speed: Float
    private(set) var sleepTimer: SleepTimer?
    /// When a timed sleep timer pauses playback.
    private(set) var sleepDeadline: Date?
    /// Whole-book position where an "end of chapter" timer pauses playback.
    private var sleepAtBookMs: Int?
    /// Incremented when Now Playing should come up (a new queue was started).
    private(set) var presentationRequests = 0
    /// Incremented when an audiobook's saved position changed, so pages can refresh.
    private(set) var progressRevision = 0

    var hasContent: Bool { content != nil && !queue.isEmpty }
    var current: Item? { queue.current?.element }
    var currentTrack: Track? { current?.track }

    var book: BookDetail? {
        if case .audiobook(let book) = content { return book }
        return nil
    }

    var durationSec: Double {
        Double(current?.durationMs ?? 0) / 1000
    }

    /// For audiobooks: the position on the whole-book timeline.
    var bookPositionMs: Int {
        guard let book, let index = currentPartIndex else { return 0 }
        return book.audiobookTimeline.bookMs(partIndex: index, offsetMs: Int(position * 1000))
    }

    var currentChapter: Chapter? {
        guard let book else { return nil }
        return AudiobookTimeline.chapter(at: bookPositionMs, in: book.chapters)
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
    @ObservationIgnored private var transcodedStreams: [String: Bool] = [:]
    @ObservationIgnored private var scrobble: ScrobbleTracker?
    @ObservationIgnored private var reporter: ProgressReporter?
    @ObservationIgnored private var pendingSeek: Double?
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var observers: [NSKeyValueObservation] = []
    @ObservationIgnored private var notificationTokens: [NSObjectProtocol] = []
    @ObservationIgnored private var itemObservers: [ObjectIdentifier: [NSKeyValueObservation]] = [:]
    @ObservationIgnored private var noticeTask: Task<Void, Never>?
    /// Queues the rest of a paged song list behind the current queue (`play(tracks:startAt:continuing:)`).
    @ObservationIgnored private var queueFill: Task<Void, Never>?
    @ObservationIgnored private var nowPlaying: NowPlayingCenter!
    @ObservationIgnored private let defaults = UserDefaults.standard
    /// Bumped by every start and stop, so a start that is still saving the previous
    /// position gives up when another one (or a stop) came after it.
    @ObservationIgnored private var startGeneration = 0
    /// Items that failed in a row; playback stops instead of cycling a failing queue.
    @ObservationIgnored private var consecutiveFailures = 0

    private static let speedKey = "audio.audiobookSpeed"
    private static let maxConsecutiveFailures = 3
    /// Audiobook part formats AVPlayer plays as sent (`BookFile.format`).
    private static let nativeFormats: Set<String> = ["MP3", "M4A", "M4B", "AAC", "ALAC", "FLAC", "WAV", "AIFF", "AIF"]

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
        let saved = defaults.float(forKey: Self.speedKey)
        speed = Self.speeds.contains(saved) ? saved : 1
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
        let center = NotificationCenter.default
        notificationTokens = [
            center.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: nil, queue: .main) { [weak self] note in
                let item = note.object as? AVPlayerItem
                MainActor.assumeIsolated { self?.itemEnded(item) }
            },
            center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.saveProgress() }
            },
            center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
                let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init(rawValue:))
                MainActor.assumeIsolated {
                    if type == .began { self?.saveProgress() }
                }
            },
        ]
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
                    guard let self, !Task.isCancelled, self.content == .music else { return false }
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
        return Task { await start(.music, queue: newQueue, at: 0) }
    }

    /// Plays an audiobook from its saved position (or `bookMs` when given).
    func play(book: BookDetail, fromBookMs bookMs: Int? = nil) {
        guard !book.files.isEmpty else { return }
        let startMs = bookMs ?? ResumePolicy.audiobookStartMs(book)
        let location = book.audiobookTimeline.locate(bookMs: startMs)
        let items = book.files.indices.map { Item(book: book, partIndex: $0) }
        queueFill?.cancel()
        let newQueue = PlayQueue(items, startAt: location?.partIndex ?? 0)
        Task { await start(.audiobook(book), queue: newQueue, at: Double(location?.offsetMs ?? 0) / 1000) }
    }

    /// Adds songs right after the current one, or plays them when nothing is playing.
    func playNext(_ tracks: [Track]) {
        guard content == .music, !queue.isEmpty else { return play(tracks: tracks) }
        queue.insertNext(tracks.map(Item.init(track:)))
        refreshUpcoming()
        showNotice(String(localized: "Playing next", bundle: .localized))
    }

    /// Adds songs to the end of the queue, or plays them when nothing is playing.
    func addToQueue(_ tracks: [Track]) {
        guard content == .music, !queue.isEmpty else { return play(tracks: tracks) }
        queue.append(contentsOf: tracks.map(Item.init(track:)))
        refreshUpcoming()
        showNotice(String(localized: "Added to queue", bundle: .localized))
    }

    /// Asks the shell to show Now Playing.
    func requestPresentation() {
        guard hasContent else { return }
        presentationRequests += 1
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
        player.playImmediately(atRate: playbackRate)
    }

    func pause() {
        player.pause()
        saveProgress()
    }

    /// Stops playback and empties the player; the audiobook position is saved in the background.
    func stop() {
        let save = halt()
        Task { await save() }
    }

    /// Stops playback and waits until the audiobook position is written, e.g. before the
    /// profile's token is revoked.
    func stopAndFlush() async {
        await halt()()
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
        notificationTokens.forEach(NotificationCenter.default.removeObserver)
        notificationTokens = []
        noticeTask?.cancel()
        nowPlaying.invalidate()
    }

    /// Empties the player and returns the write of the final audiobook position.
    private func halt() -> @MainActor () async -> Void {
        startGeneration += 1
        queueFill?.cancel()
        let reporter = reporter
        let bookMs = bookPositionMs
        let durationMs = book?.durationMs ?? 0
        player.pause()
        player.removeAllItems()
        loaded = [:]
        itemObservers = [:]
        content = nil
        queue = PlayQueue()
        position = 0
        scrobble = nil
        cancelSleepTimer()
        self.reporter = nil
        nowPlaying.clear()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        return { [weak self] in
            guard let reporter else { return }
            await reporter.update(positionMs: bookMs, durationMs: durationMs)
            await reporter.stop()
            self?.progressRevision += 1
        }
    }

    /// Next song, or next chapter of an audiobook.
    func next() {
        if let book {
            if let start = AudiobookTimeline.nextChapterStart(from: bookPositionMs, in: book.chapters) {
                seek(toBookMs: start)
            }
            return
        }
        guard let index = queue.nextIndex else { return }
        Task { await load(index: index, at: 0) }
    }

    /// Previous song (or the start of this one after 3 s), or previous chapter.
    func previous() {
        if let book {
            seek(toBookMs: AudiobookTimeline.previousChapterStart(from: bookPositionMs, in: book.chapters))
            return
        }
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

    func skip(by seconds: Double) {
        if book != nil {
            seek(toBookMs: max(0, bookPositionMs + Int(seconds * 1000)))
        } else {
            seek(to: min(max(0, position + seconds), max(0, durationSec - 1)))
        }
    }

    func setShuffle(_ on: Bool) {
        guard content == .music else { return }
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

    // MARK: - Audiobook controls

    func setSpeed(_ value: Float) {
        speed = value
        defaults.set(value, forKey: Self.speedKey)
        player.defaultRate = playbackRate
        if isPlaying { player.rate = playbackRate }
        nowPlaying.update()
    }

    func setSleepTimer(_ timer: SleepTimer?) {
        sleepTimer = timer
        switch timer {
        case .minutes(let minutes):
            sleepDeadline = Date().addingTimeInterval(TimeInterval(minutes * 60))
            sleepAtBookMs = nil
        case .endOfChapter:
            sleepDeadline = nil
            if let book {
                sleepAtBookMs = AudiobookTimeline.chapterEnd(at: bookPositionMs, in: book.chapters, totalMs: book.durationMs)
            }
        case nil:
            cancelSleepTimer()
        }
    }

    func seek(toBookMs bookMs: Int) {
        guard let book, let location = book.audiobookTimeline.locate(bookMs: bookMs) else { return }
        if location.partIndex == queue.currentIndex {
            seek(to: Double(location.offsetMs) / 1000)
        } else {
            Task { await load(index: location.partIndex, at: Double(location.offsetMs) / 1000) }
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

    private func start(_ newContent: Content, queue newQueue: PlayQueue<Item>, at offset: Double) async {
        startGeneration += 1
        let generation = startGeneration
        consecutiveFailures = 0
        if let reporter {
            // Taken first, so a start that runs meanwhile does not save it again.
            self.reporter = nil
            let bookMs = bookPositionMs
            let durationMs = book?.durationMs ?? 0
            await reporter.update(positionMs: bookMs, durationMs: durationMs)
            await reporter.stop()
            guard generation == startGeneration else { return }
        }
        if content != newContent {
            cancelSleepTimer()
        }
        content = newContent
        queue = newQueue
        notice = nil
        if case .audiobook(let book) = newContent, let client = appState?.client {
            let reporter = ProgressReporter(client: client, itemId: book.id, interval: 10, minimumChangeMs: 1000)
            self.reporter = reporter
            await reporter.start()
            guard generation == startGeneration else {
                await reporter.stop()
                return
            }
        }
        presentationRequests += 1
        guard let index = queue.currentIndex else { return }
        await load(index: index, at: offset)
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
        player.playImmediately(atRate: playbackRate)
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
        let item = AVPlayerItem(url: url)
        item.audioTimePitchAlgorithm = book != nil ? .timeDomain : .spectral
        return item
    }

    private func streamURL(for item: Item, offset: Double, forceTranscode: Bool) -> URL? {
        guard let urls = appState?.client?.urls else { return nil }
        let accept = forceTranscode ? AudioCodec.apple.filter { $0 != .flac } : AudioCodec.apple
        let format: AudioTranscodeFormat? = forceTranscode ? .aac : nil
        let start = offset > 0 ? offset : nil
        switch item.source {
        case .track(let track):
            return urls.trackStream(trackId: track.id, accept: accept, format: format, startSec: start, mediaKey: mediaKey)
        case .audiobookPart(let fileId, _):
            return urls.audio(fileId: fileId, accept: accept, format: format, startSec: start, mediaKey: mediaKey)
        }
    }

    /// Whether the server transcodes this item for our `accept` list: from the part's
    /// format for audiobooks, otherwise from the stream's response headers (a transcode
    /// has `X-Vault-Transcode: 1` and `Accept-Ranges: none`). Cached per stream.
    private func transcoding(_ item: Item) async -> Bool {
        if let known = knownTranscoding(item) { return known }
        guard let url = streamURL(for: item, offset: 0, forceTranscode: false) else { return false }
        let key = Self.streamKey(item)
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
        if let known = transcodedStreams[Self.streamKey(item)] { return known }
        if case .audiobookPart(_, let index) = item.source, let book, book.files.indices.contains(index) {
            let format = book.files[index].format.uppercased()
            if !format.isEmpty { return !Self.nativeFormats.contains(format) }
        }
        return nil
    }

    private static func streamKey(_ item: Item) -> String {
        switch item.source {
        case .track(let track): return "track-\(track.id)"
        case .audiobookPart(let fileId, _): return "audio-\(fileId)"
        }
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
            transcodedStreams[Self.streamKey(entry.element)] = true
            let offset = isCurrent ? position : 0
            register(retry, entry: entry, offset: offset, transcoded: true, acceptsFLAC: false)
            player.insert(retry, after: playerItem)
            player.remove(playerItem)
            forget(playerItem)
            if isCurrent { player.playImmediately(atRate: playbackRate) }
            return
        }
        player.remove(playerItem)
        forget(playerItem)
        guard isCurrent else { return }
        consecutiveFailures += 1
        if consecutiveFailures >= min(queue.count, Self.maxConsecutiveFailures) {
            player.pause()
            saveProgress()
            showNotice(String(localized: "Playback stopped because the server isn’t sending audio. Try again later.", bundle: .localized))
            return
        }
        showNotice(String(localized: "Couldn’t play “\(entry.element.title)”.", bundle: .localized))
        if let next = queue.nextIndex, next != queue.currentIndex {
            Task { await load(index: next, at: 0) }
        }
    }

    private func itemEnded(_ playerItem: AVPlayerItem?) {
        guard let playerItem, loaded[ObjectIdentifier(playerItem)] != nil else { return }
        if book != nil, queue.indexAfterCurrentEnds == nil {
            // The last part ended: the book is finished.
            saveProgress(atEnd: true)
        }
    }

    private func finishedQueue() {
        isPlaying = false
        position = durationSec
        saveProgress(atEnd: book != nil)
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
        if let reporter, let book {
            let bookMs = bookPositionMs
            Task { await reporter.update(positionMs: bookMs, durationMs: book.durationMs) }
        }
        checkSleepTimer()
    }

    /// Bookkeeping when an item becomes current.
    private func startedItem(_ entry: PlayQueue<Item>.Entry) {
        if let track = entry.element.track {
            scrobble = ScrobbleTracker(trackId: track.id, durationMs: track.durationMs)
        } else {
            scrobble = nil
        }
        nowPlaying.update()
    }

    private func recordPlay(trackId: Int) {
        guard let client = appState?.client else { return }
        Task { try? await client.recordPlay(trackId: trackId, at: Date()) }
    }

    /// Writes the audiobook position now (pause, background, stop).
    private func saveProgress(atEnd: Bool = false) {
        guard let reporter, let book else { return }
        let bookMs = atEnd ? book.durationMs : bookPositionMs
        Task {
            await reporter.update(positionMs: bookMs, durationMs: book.durationMs)
            await reporter.flush()
            progressRevision += 1
        }
    }

    // MARK: - Sleep timer

    private func checkSleepTimer() {
        guard isPlaying else { return }
        if let deadline = sleepDeadline, Date() >= deadline {
            cancelSleepTimer()
            pause()
        } else if let end = sleepAtBookMs, bookPositionMs >= end {
            cancelSleepTimer()
            pause()
        }
    }

    private func cancelSleepTimer() {
        sleepTimer = nil
        sleepDeadline = nil
        sleepAtBookMs = nil
    }

    // MARK: - Helpers

    private var currentPartIndex: Int? {
        if case .audiobookPart(_, let index) = current?.source { return index }
        return nil
    }

    private var playbackRate: Float {
        book != nil ? speed : 1
    }

    private func activateSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: book != nil ? .spokenAudio : .default)
        try? session.setActive(true)
        player.defaultRate = playbackRate
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
