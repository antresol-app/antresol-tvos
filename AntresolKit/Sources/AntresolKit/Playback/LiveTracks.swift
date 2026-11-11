import Foundation

/// The profile's audio and subtitle defaults (`GET /api/me/playback-prefs`).
public struct PlaybackPrefs: Decodable, Hashable, Sendable {
    /// Two-letter codes, best first.
    public var audioLangs: [String]
    /// "off", "always" or "foreign" (when the audio is not in `audioLangs`).
    public var subMode: String
    public var subLangs: [String]
    /// «Выбирать очищенную озвучку».
    public var preferCleaned: Bool

    public init(audioLangs: [String] = ["ru"], subMode: String = "off", subLangs: [String] = [], preferCleaned: Bool = false) {
        self.audioLangs = audioLangs
        self.subMode = subMode
        self.subLangs = subLangs
        self.preferCleaned = preferCleaned
    }

    enum CodingKeys: String, CodingKey { case audioLangs, subMode, subLangs, preferCleaned }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        audioLangs = c.value(.audioLangs, default: ["ru"])
        subMode = c.value(.subMode, default: "off")
        subLangs = c.value(.subLangs, default: [])
        preferCleaned = c.value(.preferCleaned, default: false)
    }
}

/// The live player's audio and subtitles. The live stream carries fixed renditions (audio
/// slots `ru`, `ru2`, `en`, `orig`; subtitle slots `ru`, `en`); each programme says which it
/// really has. The profile's defaults pick a slot per programme until the viewer picks one
/// in the player: that pick then sticks for the rest of the session, across programmes
/// and channels, and is never sent to the server (TV is TV).
public struct LiveTrackSelection: Hashable, Sendable {
    /// What the viewer picked in this session: an audio slot.
    public var audioSlot: String?
    /// What the viewer picked: a subtitle slot, or "" for off; nil while the defaults apply.
    public var subtitleSlot: String?

    public init(audioSlot: String? = nil, subtitleSlot: String? = nil) {
        self.audioSlot = audioSlot
        self.subtitleSlot = subtitleSlot
    }

    /// The fallback slot every programme has (its best Russian track).
    public static let fallbackAudioSlot = "ru"

    /// The audio slot to play for a programme with `audio` (nil: unknown).
    public func audio(for audio: [LiveTrack]?, prefs: PlaybackPrefs) -> String {
        if let audioSlot { return audioSlot }
        guard let audio, !audio.isEmpty else { return Self.fallbackAudioSlot }
        for lang in prefs.audioLangs {
            if let hit = audio.first(where: { Self.language(of: $0) == lang }) { return hit.slot }
        }
        return Self.fallbackAudioSlot
    }

    /// The subtitle slot to show (nil: off) for a programme with `subtitles`, while the
    /// audio plays `audioSlot`.
    public func subtitle(for subtitles: [LiveTrack]?, audio: [LiveTrack]?, audioSlot: String, prefs: PlaybackPrefs) -> String? {
        if let subtitleSlot { return subtitleSlot.isEmpty ? nil : subtitleSlot }
        guard let subtitles, !subtitles.isEmpty else { return nil }
        let wanted: Bool
        switch prefs.subMode {
        case "always":
            wanted = true
        case "foreign":
            let playing = audio?.first { $0.slot == audioSlot }
            let lang = playing.map(Self.language(of:)) ?? Self.slotLanguage(audioSlot)
            wanted = !lang.isEmpty && !prefs.audioLangs.contains(lang)
        default:
            wanted = false
        }
        guard wanted else { return nil }
        let langs = prefs.subLangs.isEmpty ? prefs.audioLangs : prefs.subLangs
        for lang in langs {
            if let hit = subtitles.first(where: { Self.language(of: $0) == lang }) { return hit.slot }
        }
        return nil
    }

    /// A track's two-letter language: its `lang`, else its slot's.
    static func language(of track: LiveTrack) -> String {
        let lang = LanguageCode.known(track.lang).map(Self.twoLetter) ?? ""
        return lang.isEmpty ? slotLanguage(track.slot) : lang
    }

    /// The language of a fixed slot ("ru" for `ru` and `ru2`, "en"; "" for `orig`).
    public static func slotLanguage(_ slot: String) -> String {
        switch slot {
        case "ru", "ru2": return "ru"
        case "en": return "en"
        default: return ""
        }
    }

    private static func twoLetter(_ code: String) -> String {
        switch code.lowercased() {
        case "rus": return "ru"
        case "eng": return "en"
        default: return code.lowercased().count == 2 ? code.lowercased() : String(code.lowercased().prefix(2))
        }
    }
}
