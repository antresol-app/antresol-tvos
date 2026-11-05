import Foundation

/// User choices that shape a `/api/play` request.
public struct PlaybackOptions: Hashable, Sendable {
    public var quality: VideoQuality?
    public var audioIndex: Int?
    public var burnSubtitle: Int?

    public init(quality: VideoQuality? = nil, audioIndex: Int? = nil, burnSubtitle: Int? = nil) {
        self.quality = quality
        self.audioIndex = audioIndex
        self.burnSubtitle = burnSubtitle
    }
}

/// What the player should load, plus the mapping between player and file time.
public struct PlaybackSource: Hashable, Sendable {
    public let response: PlayResponse
    /// Absolute URL, signed with the media key so the player needs no headers.
    public let url: URL
    /// File position (seconds) where playback should begin.
    public let startPosition: Double

    /// - Parameter startPosition: where to begin; defaults to the response's `startSec`.
    public init(response: PlayResponse, url: URL, startPosition: Double? = nil) {
        self.response = response
        self.url = url
        self.startPosition = max(0, startPosition ?? response.startSec)
    }

    public var mode: PlaybackMode { response.mode }

    public var hlsSessionID: String? { response.hlsSessionID }

    /// File position (seconds) at player time 0: `startSec` for HLS, 0 for direct play.
    public var timelineOffset: Double {
        mode.isHLS ? response.startSec : 0
    }

    /// Where to seek after loading (player seconds): the start position on the player
    /// timeline, never before its beginning.
    public var initialPlayerSeek: Double {
        max(0, playerTime(filePosition: startPosition))
    }

    public var durationSec: Double {
        Double(response.durationMs) / 1000
    }

    public func filePosition(playerTime: Double) -> Double {
        timelineOffset + playerTime
    }

    public func playerTime(filePosition: Double) -> Double {
        filePosition - timelineOffset
    }

    /// Whether the player can reach `filePosition` itself. HLS cannot seek before its
    /// start, and an incomplete (EVENT) playlist only covers what has been produced, so
    /// those cases need a new `/api/play` with `replaceSession`.
    public func canSeekInPlayer(toFilePosition position: Double) -> Bool {
        guard mode.isHLS else { return true }
        return position >= timelineOffset && response.hlsComplete
    }
}

/// Why a running HLS session ended on the server side.
public enum PlaybackSessionEnd: Sendable, Equatable {
    /// The server forgot the session (keepalive `404`): start again at the current position.
    case expired
    /// The token was revoked (keepalive `401`): the profile has to sign in again.
    case unauthorized
}

/// Drives one video file's server-side playback: `/api/play`, the 20-second HLS
/// keepalive, session replacement for seeks and track changes, and cleanup (§5, §11).
///
/// Calls to `start(at:options:)` run one at a time, so two quick track changes cannot
/// both replace the same session. `stop()` always wins: a start still waiting for the
/// server when `stop()` runs deletes the session it created and throws
/// `CancellationError`, so no server session is left without a keepalive or a DELETE.
public actor VideoPlaybackSession {
    public let fileId: Int
    private let client: APIClient
    private let mediaKeys: MediaKeyStore
    private let caps: DeviceCaps
    private let keepAliveInterval: TimeInterval
    private var keepAliveTask: Task<Void, Never>?
    private var endHandler: (@Sendable (PlaybackSessionEnd) -> Void)?
    /// Bumped by `stop()`; a start that began in an older epoch gives up.
    private var epoch = 0
    private var isStarting = false
    private var waitingStarts: [CheckedContinuation<Void, Never>] = []

    public private(set) var current: PlaybackSource?
    public private(set) var options = PlaybackOptions()

    public init(
        client: APIClient, mediaKeys: MediaKeyStore, fileId: Int,
        caps: DeviceCaps = .appleTV(), keepAliveInterval: TimeInterval = 20
    ) {
        self.client = client
        self.mediaKeys = mediaKeys
        self.fileId = fileId
        self.caps = caps
        self.keepAliveInterval = keepAliveInterval
    }

    deinit {
        keepAliveTask?.cancel()
    }

    /// Called when the server ends the HLS session: `.expired` (start again with
    /// `start(at:)` at the current file position) or `.unauthorized` (sign in again).
    public func onEnded(_ handler: @escaping @Sendable (PlaybackSessionEnd) -> Void) {
        endHandler = handler
    }

    /// Starts playback at `position` (file seconds), replacing the current HLS session if
    /// there is one. Passing `options` changes quality, audio or burned subtitle; they are
    /// kept only when the start succeeds.
    ///
    /// The server is asked for the whole file (`startSec` 0) and the player seeks to
    /// `position` itself: direct play always works that way, and a complete (VOD) HLS
    /// playlist then spans the full timeline, so the transport bar can seek anywhere,
    /// backwards included; the server produces segments on demand. Only a growing (EVENT)
    /// playlist, which covers just what has been produced, is requested at `position`.
    @discardableResult
    public func start(at position: Double, options newOptions: PlaybackOptions? = nil) async throws -> PlaybackSource {
        await acquireStart()
        defer { releaseStart() }
        let startEpoch = epoch
        let requested = newOptions ?? options
        let position = max(0, position)
        // The key comes first so a failure here leaves no server session behind.
        let key = try await mediaKeys.key()
        try ensureCurrent(startEpoch)

        let replaced = current?.hlsSessionID
        keepAliveTask?.cancel()
        keepAliveTask = nil
        // Sessions this call created that are not yet `current`.
        var created: String?
        do {
            var response = try await requestPlay(startSec: 0, replacing: replaced, options: requested)
            created = response.hlsSessionID
            try ensureCurrent(startEpoch)
            if response.mode.isHLS, !response.hlsComplete, position > 0 {
                response = try await requestPlay(startSec: position, replacing: response.hlsSessionID, options: requested)
                created = response.hlsSessionID
                try ensureCurrent(startEpoch)
            }
            guard let url = client.urls.playback(response, mediaKey: key) else {
                throw APIError.invalidURL(response.url)
            }
            let source = PlaybackSource(response: response, url: url, startPosition: position)
            current = source
            options = requested
            restartKeepAlive()
            return source
        } catch {
            if let created {
                try? await client.stop(hlsSession: created)
            }
            if epoch == startEpoch {
                if created != nil || replaced == nil {
                    // The server already replaced the old session (or there was none).
                    current = nil
                } else {
                    // The old session is untouched: keep it alive.
                    restartKeepAlive()
                }
            }
            throw error
        }
    }

    private func ensureCurrent(_ startEpoch: Int) throws {
        if epoch != startEpoch || Task.isCancelled { throw CancellationError() }
    }

    private func acquireStart() async {
        if isStarting {
            await withCheckedContinuation { waitingStarts.append($0) }
        } else {
            isStarting = true
        }
    }

    private func releaseStart() {
        if waitingStarts.isEmpty {
            isStarting = false
        } else {
            waitingStarts.removeFirst().resume()
        }
    }

    private func requestPlay(startSec: Double, replacing session: String?, options: PlaybackOptions) async throws -> PlayResponse {
        // The server ignores an unknown `replaceSession`, so an expired one needs no fallback.
        let request = PlayRequest(
            caps: caps,
            startSec: startSec,
            quality: options.quality,
            audioIndex: options.audioIndex,
            replaceSession: session,
            burnSubtitle: options.burnSubtitle
        )
        return try await client.play(fileId: fileId, request)
    }

    /// Stops keepalive and deletes the HLS session. Call when the player closes or goes
    /// to the background; a start in flight gives up. `start(at:)` may be called again later.
    public func stop() async {
        epoch += 1
        keepAliveTask?.cancel()
        keepAliveTask = nil
        let session = current?.hlsSessionID
        current = nil
        if let session {
            try? await client.stop(hlsSession: session)
        }
    }

    private func restartKeepAlive() {
        keepAliveTask?.cancel()
        keepAliveTask = nil
        guard let session = current?.hlsSessionID else { return }
        let interval = UInt64(keepAliveInterval * 1_000_000_000)
        keepAliveTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: interval)
                guard !Task.isCancelled, let self else { return }
                guard await self.keepAlive(session) else { return }
            }
        }
    }

    /// One keepalive ping; false when the loop should end.
    private func keepAlive(_ session: String) async -> Bool {
        guard current?.hlsSessionID == session else { return false }
        do {
            try await client.keepAlive(hlsSession: session)
            return true
        } catch let error as APIError where error.isNotFound || error.statusCode == 401 {
            guard current?.hlsSessionID == session else { return false }
            keepAliveTask = nil
            current = nil
            endHandler?(error.isNotFound ? .expired : .unauthorized)
            return false
        } catch {
            // Transient failure: try again on the next tick.
            return true
        }
    }
}
