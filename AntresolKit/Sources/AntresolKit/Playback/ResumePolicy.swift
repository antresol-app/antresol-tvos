import Foundation

/// Where to resume playback, following the web app's rules.
public enum ResumePolicy {
    /// Video resume point in seconds: the stored position unless finished.
    public static func videoStartSec(_ progress: PlaybackProgress?) -> Double {
        guard let progress, progress.exists, !progress.finished else { return 0 }
        return Double(progress.positionMs) / 1000
    }
}
