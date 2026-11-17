import Foundation

/// How a seek inside the current song is carried out.
public enum SongSeek: Equatable, Sendable {
    /// The player seeks (an original file with byte ranges).
    case native
    /// The stream is asked for again from the target: a transcoded song has no ranges.
    case reload
    /// Kept until the item is ready, when it is decided again: a song whose kind is not
    /// known yet may turn out to be transcoded.
    case hold

    /// - Parameters:
    ///   - knownTranscoded: the server said it transcodes the song.
    ///   - isReady: the player item is ready to play.
    ///   - hasSeekableRanges: the ready item has something to seek in (a stream with
    ///     nothing seekable is a transcode the headers did not reveal).
    public static func plan(knownTranscoded: Bool, isReady: Bool, hasSeekableRanges: Bool) -> SongSeek {
        if knownTranscoded { return .reload }
        guard isReady else { return .hold }
        return hasSeekableRanges ? .native : .reload
    }
}

/// How a seek that was held (`SongSeek.hold`) is carried out once the item is ready.
public enum HeldSongSeek: Equatable, Sendable {
    /// The player seeks.
    case native
    /// The stream is asked for again from the target. `remember`: the song is taken as
    /// transcoded from now on (for the session); otherwise the reload asks the server
    /// about the song first, as any start inside a song does.
    case reload(remember: Bool)

    /// A ready item with nothing to seek in is a transcode the headers did not reveal,
    /// or an original file whose ranges are not there yet (a progressive file whose
    /// length is still unknown), so that alone does not make a song transcoded:
    /// - Parameters:
    ///   - knownTranscoded: the item was loaded as, or learned to be, a transcode.
    ///   - serverAnswer: what the server said about the song (nil: no answer yet, or
    ///     the request failed).
    ///   - hasSeekableRanges: the ready item has something to seek in.
    ///   - reloadedBefore: this song was already reloaded once for a held seek, and is
    ///     without ranges and without the server's answer again.
    public static func plan(knownTranscoded: Bool, serverAnswer: Bool?, hasSeekableRanges: Bool, reloadedBefore: Bool) -> HeldSongSeek {
        if knownTranscoded || serverAnswer == true { return .reload(remember: false) }
        if hasSeekableRanges { return .native }
        // The server said it is the original file: the ranges are only late.
        if serverAnswer == false { return .native }
        return .reload(remember: reloadedBefore)
    }
}
