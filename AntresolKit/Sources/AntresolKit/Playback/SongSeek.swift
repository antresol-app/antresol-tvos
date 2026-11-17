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
