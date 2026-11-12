import Foundation

/// Everything the TV tab, the guide and the live player say to the server. TV is TV: a
/// channel leaves no trace in the library — no progress, no playback reports, no resume
/// or «Продолжить просмотр», no watched marks, no remembered tracks
/// (`/api/items/{id}/track-prefs`), no scrobbles. The only writes are the profile's
/// favourite channels and its last channel; the audio and subtitle picks of the live
/// player stay on the device. `LiveTVTests` holds the app to that through this type.
public struct ChannelService: Sendable {
    public let client: APIClient

    public init(client: APIClient) {
        self.client = client
    }

    /// The one list, by number, with the last channel.
    public func list() async throws -> ChannelList {
        try await client.channels()
    }

    public func epg(from: Date?, hours: Int = 6) async throws -> ChannelEPGWindow {
        try await client.channelEPG(from: from, hours: hours)
    }

    public func guide(channelId: Int, hours: Int = 6) async throws -> ChannelGuide {
        try await client.channelGuide(id: channelId, hours: hours)
    }

    public func playbackPrefs() async throws -> PlaybackPrefs {
        try await client.playbackPrefs()
    }

    public func setFavorite(channelId: Int, _ favorite: Bool) async throws {
        try await client.setChannelFavorite(id: channelId, favorite)
    }

    /// Starts the channel's stream and returns the playlist URL for the player; once the
    /// server serves it, the channel becomes the profile's last channel (a failure to
    /// say so does not stop the picture).
    public func tuneIn(
        channelId: Int, mediaKey: String?, onStarting: @Sendable () async -> Void = {}
    ) async throws -> URL {
        try await tuneInStream(channelId: channelId, mediaKey: mediaKey, onStarting: onStarting).url
    }

    /// `tuneIn` with the master playlist's renditions (which option is which NAME).
    public func tuneInStream(
        channelId: Int, mediaKey: String?, onStarting: @Sendable () async -> Void = {}
    ) async throws -> LiveStream {
        let stream = try await client.startLiveStream(id: channelId, mediaKey: mediaKey, onStarting: onStarting)
        try? await client.setLastChannel(id: channelId)
        return stream
    }

    /// The requests a channel may write: favourites and the last channel. Anything else
    /// that is not a read is a leak into the profile's history.
    public static func isAllowedWrite(method: String, path: String) -> Bool {
        let parts = path.split(separator: "/").map(String.init)
        switch method {
        case "PUT":
            return parts == ["api", "channels", "last"]
                || (parts.count == 4 && parts[0] == "api" && parts[1] == "channels" && Int(parts[2]) != nil && parts[3] == "favorite")
        case "DELETE":
            return parts.count == 4 && parts[0] == "api" && parts[1] == "channels" && Int(parts[2]) != nil && parts[3] == "favorite"
        default:
            return false
        }
    }
}
