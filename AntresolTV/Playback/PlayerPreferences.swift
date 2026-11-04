import AntresolKit
import Foundation

/// Player choices remembered across videos: preferred audio and subtitle languages,
/// streaming quality and next-episode autoplay.
struct PlayerPreferences {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private enum Key {
        static let audioLanguage = "player.audioLanguage"
        static let subtitleLanguage = "player.subtitleLanguage"
        static let quality = "player.quality"
        static let autoplayNext = "player.autoplayNext"
    }

    /// Two-letter code of the last audio language picked from the menu.
    var audioLanguage: String? {
        get { defaults.string(forKey: Key.audioLanguage) }
        nonmutating set { defaults.set(newValue, forKey: Key.audioLanguage) }
    }

    /// Two-letter code of the last subtitle language picked; nil means subtitles off.
    var subtitleLanguage: String? {
        get { defaults.string(forKey: Key.subtitleLanguage) }
        nonmutating set { defaults.set(newValue, forKey: Key.subtitleLanguage) }
    }

    var quality: VideoQuality {
        get { defaults.string(forKey: Key.quality).flatMap(VideoQuality.init(rawValue:)) ?? .auto }
        nonmutating set { defaults.set(newValue.rawValue, forKey: Key.quality) }
    }

    /// Whether the next episode starts by itself after the countdown (default on).
    var autoplayNext: Bool {
        get { defaults.object(forKey: Key.autoplayNext) as? Bool ?? true }
        nonmutating set { defaults.set(newValue, forKey: Key.autoplayNext) }
    }

    /// The audio track to request: the preferred language when the file has it and it
    /// is not the default track anyway (picking another track forces a remux).
    func audioIndex(for tracks: [AudioTrack]) -> Int? {
        guard let preferred = audioLanguage,
              let match = tracks.first(where: { TrackLabels.normalizedLanguage($0.language) == preferred }),
              !match.isDefault, tracks.count > 1
        else { return nil }
        return match.index
    }

    /// The text subtitle to show at start: one in the preferred language, full tracks
    /// before forced ones.
    func subtitle(for tracks: [SubtitleTrack]) -> SubtitleTrack? {
        guard let preferred = subtitleLanguage else { return nil }
        let matching = tracks.filter { $0.isText && TrackLabels.normalizedLanguage($0.language) == preferred }
        return matching.first { !$0.forced } ?? matching.first
    }
}

extension VideoQuality {
    var displayName: String {
        switch self {
        case .auto: return String(localized: "Auto")
        case .original: return String(localized: "Original")
        case .p1080: return "1080p"
        case .p720: return "720p"
        case .p480: return "480p"
        }
    }
}
