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

    public init(response: PlayResponse, url: URL) {
        self.response = response
        self.url = url
    }

    public var mode: PlaybackMode { response.mode }

    public var hlsSessionID: String? { response.hlsSessionID }

    /// File position (seconds) at player time 0: `startSec` for HLS, 0 for direct play.
    public var timelineOffset: Double {
        mode.isHLS ? response.startSec : 0
    }

    /// Where to seek after loading: direct play starts at 0 and seeks itself.
    public var initialPlayerSeek: Double {
        mode.isHLS ? 0 : response.startSec
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

/// Drives one video file's server-side playback: `/api/play`, the 20-second HLS
/// keepalive, session replacement for seeks and track changes, and cleanup (§5, §11).
public actor VideoPlaybackSession {
    public let fileId: Int
    private let client: APIClient
    private let mediaKeys: MediaKeyStore
    private let caps: DeviceCaps
    private let keepAliveInterval: TimeInterval
    private var keepAliveTask: Task<Void, Never>?
    private var expirationHandler: (@Sendable () -> Void)?

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

    /// Called when the server reports the HLS session gone (keepalive `404`). Start
    /// again with `start(at:)` at the current file position.
    public func onExpired(_ handler: @escaping @Sendable () -> Void) {
        expirationHandler = handler
    }

    /// Starts playback at `startSec` (file seconds), replacing the current HLS session
    /// if there is one. Passing `options` changes quality, audio or burned subtitle.
    @discardableResult
    public func start(at startSec: Double, options newOptions: PlaybackOptions? = nil) async throws -> PlaybackSource {
        if let newOptions { options = newOptions }
        let request = PlayRequest(
            caps: caps,
            startSec: max(0, startSec),
            quality: options.quality,
            audioIndex: options.audioIndex,
            replaceSession: current?.hlsSessionID,
            burnSubtitle: options.burnSubtitle
        )
        let response: PlayResponse
        do {
            response = try await client.play(fileId: fileId, request)
        } catch let error as APIError where error.isNotFound && request.replaceSession != nil {
            // The session to replace already expired: start a fresh one.
            current = nil
            response = try await client.play(fileId: fileId, PlayRequest(
                caps: caps, startSec: request.startSec, quality: request.quality,
                audioIndex: request.audioIndex, burnSubtitle: request.burnSubtitle
            ))
        }
        let key = try await mediaKeys.key()
        guard let url = client.urls.playback(response, mediaKey: key) else {
            throw APIError.invalidURL(response.url)
        }
        let source = PlaybackSource(response: response, url: url)
        current = source
        restartKeepAlive()
        return source
    }

    /// Stops keepalive and deletes the HLS session. Call when the player closes.
    public func stop() async {
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
        keepAliveTask = Task { [weak self, client] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: interval)
                guard !Task.isCancelled else { return }
                do {
                    try await client.keepAlive(hlsSession: session)
                } catch let error as APIError where error.isNotFound {
                    await self?.sessionExpired(session)
                    return
                } catch {
                    // Transient failure: try again on the next tick.
                }
            }
        }
    }

    private func sessionExpired(_ session: String) {
        guard current?.hlsSessionID == session else { return }
        keepAliveTask = nil
        current = nil
        expirationHandler?()
    }
}
