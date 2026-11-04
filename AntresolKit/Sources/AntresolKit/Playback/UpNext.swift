import Foundation

/// Series order and the "Up Next" timing used by the video player.
public enum UpNext {
    /// The episode after `episodeId` in a series' seasons (season, then episode order),
    /// or nil when it is the last one or not found. Specials (season 0) come last.
    public static func episode(after episodeId: Int, in seasons: [SeasonInfo]) -> EpisodeCard? {
        let ordered = seasons
            .sorted { sortKey($0.number) < sortKey($1.number) }
            .flatMap { $0.episodes.sorted { $0.episodeNo < $1.episodeNo } }
        guard let index = ordered.firstIndex(where: { $0.id == episodeId }), index + 1 < ordered.count else {
            return nil
        }
        return ordered[index + 1]
    }

    /// When to offer the next episode, in file seconds: 25 s before the end, but never
    /// before 80 % of a short file. Nil when the duration is unknown.
    public static func proposalTime(durationSec: Double, lead: Double = 25) -> Double? {
        guard durationSec > 0 else { return nil }
        return max(durationSec - lead, durationSec * 0.8)
    }

    /// Whether a stop at `positionSec` counts as having watched the item (the server
    /// marks video finished at about 92 %).
    public static func isFinished(positionSec: Double, durationSec: Double) -> Bool {
        durationSec > 0 && positionSec / durationSec >= 0.92
    }

    private static func sortKey(_ season: Int) -> Int {
        season == 0 ? Int.max : season
    }
}
