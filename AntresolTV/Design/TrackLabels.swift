import AntresolKit
import Foundation

/// Human-readable names for audio and subtitle tracks, in the interface language.
enum TrackLabels {
    /// "English Stereo" (the track title), else "English · AC3 5.1".
    static func describe(_ track: AudioTrack) -> String {
        if !track.title.isEmpty { return track.title }
        let parts = [languageName(track.language), track.codec.uppercased(), channelLayout(track.channels)]
        let text = parts.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        return text.isEmpty ? String(localized: "Track \(track.index)", bundle: .localized) : text
    }

    /// The audio menu's entry, as the web player shows it: the language as the title
    /// ("Русский"), and what the track's title adds (the studio, «Кураж-Бамбей»), its channel
    /// layout and «Очищено» for a cleaned voice-over as the detail line.
    static func menuLabel(_ track: AudioTrack) -> (title: String, detail: String) {
        let language = languageName(LanguageCode.known(track.lang))
        let name = track.title.trimmingCharacters(in: .whitespaces)
        let title = language ?? (name.isEmpty ? String(localized: "Track \(track.index)", bundle: .localized) : name)
        var parts: [String] = []
        let extra = language == nil ? "" : extraName(name, language: language ?? "", code: track.lang)
        if !extra.isEmpty { parts.append(extra) }
        if let layout = channelLayout(track.channels) { parts.append(layout) }
        if track.isCleaned { parts.append(String(localized: "Cleaned", bundle: .localized)) }
        return (title, parts.joined(separator: " · "))
    }

    /// The track title when it adds something beyond the language ("Russian", "rus" do not).
    private static func extraName(_ name: String, language: String, code: String) -> String {
        guard !name.isEmpty else { return "" }
        let lower = name.lowercased()
        if lower == language.lowercased() || lower == code.lowercased() { return "" }
        if let known = LanguageCode.known(name), languageName(known)?.lowercased() == language.lowercased(), known.count <= 3 { return "" }
        return name
    }

    /// "English", "English (Forced)", or the track title.
    static func describe(_ track: SubtitleTrack) -> String {
        var text = track.title.isEmpty ? (languageName(track.language) ?? track.codec.uppercased()) : track.title
        if text.isEmpty { text = String(localized: "Track \(track.index)", bundle: .localized) }
        if track.forced { text += " (" + String(localized: "Forced", bundle: .localized) + ")" }
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
        case 1: return String(localized: "Mono", bundle: .localized)
        case 2: return String(localized: "Stereo", bundle: .localized)
        case 6: return "5.1"
        case 8: return "7.1"
        default: return nil
        }
    }
}
