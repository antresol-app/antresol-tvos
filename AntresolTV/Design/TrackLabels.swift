import AntresolKit
import Foundation

/// Human-readable names for audio and subtitle tracks, in the interface language.
enum TrackLabels {
    /// "English Stereo" (the track title), else "English · AC3 5.1".
    static func describe(_ track: AudioTrack) -> String {
        if !track.title.isEmpty { return track.title }
        let parts = [languageName(track.language), track.codec.uppercased(), channelLayout(track.channels)]
        let text = parts.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        return text.isEmpty ? String(localized: "Track \(track.index)") : text
    }

    /// "English", "English (Forced)", or the track title.
    static func describe(_ track: SubtitleTrack) -> String {
        var text = track.title.isEmpty ? (languageName(track.language) ?? track.codec.uppercased()) : track.title
        if text.isEmpty { text = String(localized: "Track \(track.index)") }
        if track.forced { text += " (" + String(localized: "Forced") + ")" }
        return text
    }

    /// "English" for "eng" or "en", in the interface language.
    static func languageName(_ code: String?) -> String? {
        guard let code else { return nil }
        let name = Locale.current.localizedString(forLanguageCode: code) ?? code.uppercased()
        return name.prefix(1).uppercased() + name.dropFirst()
    }

    /// A two-letter code ("en" for "eng"), so preferences match either form.
    static func normalizedLanguage(_ code: String?) -> String? {
        guard let code = LanguageCode.known(code ?? "") else { return nil }
        return Locale.LanguageCode(code).identifier(.alpha2) ?? code
    }

    private static func channelLayout(_ channels: Int) -> String? {
        switch channels {
        case 1: return String(localized: "Mono")
        case 2: return String(localized: "Stereo")
        case 6: return "5.1"
        case 8: return "7.1"
        default: return nil
        }
    }
}
