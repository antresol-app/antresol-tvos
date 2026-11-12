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

/// The live player's audio and subtitles. A channel's stream carries any number of
/// renditions (up to 8 audio and 6 subtitle ones) with arbitrary names; each programme says
/// which it really has. The profile's defaults pick one per programme until the viewer picks
/// one in the player: that pick then sticks by its name for the rest of the session, across
/// programmes and channels (by its language where a channel has no such name), and is never
/// sent to the server (TV is TV).
public struct LiveTrackSelection: Hashable, Sendable {
    /// A pick: the rendition's name and language.
    public struct Pick: Hashable, Sendable {
        public var name: String
        public var lang: String

        public init(name: String, lang: String) {
            self.name = name
            self.lang = lang
        }

        public init(_ track: LiveTrack) {
            self.init(name: track.name, lang: track.lang)
        }
    }

    /// What the viewer picked in this session (nil: the profile's default).
    public var audio: Pick?
    /// nil while the defaults apply, `.some(nil)` off, `.some(pick)` that one.
    public var subtitle: Pick??

    public init(audio: Pick? = nil, subtitle: Pick?? = nil) {
        self.audio = audio
        self.subtitle = subtitle
    }

    /// The device's languages, most wanted first (`Locale.preferredLanguages`). Tests set it.
    nonisolated(unsafe) public static var deviceLanguages: [String] = Locale.preferredLanguages

    /// The voice to play among `tracks`: the viewer's pick by name, else the first of its
    /// language; else the first entry in the device's system language; else in the first of
    /// the profile's languages present; else the original («Оригинал …»), else the first.
    /// nil when there are none.
    public func audio(in tracks: [LiveTrack], prefs: PlaybackPrefs, device: [String] = LiveTrackSelection.deviceLanguages) -> LiveTrack? {
        guard !tracks.isEmpty else { return nil }
        if let audio {
            if let hit = tracks.first(where: { $0.name == audio.name }) { return hit }
            let lang = Self.language(audio.lang)
            if !lang.isEmpty, let hit = tracks.first(where: { Self.language(of: $0) == lang }) { return hit }
        }
        for lang in (device + prefs.audioLangs).map(Self.language) where !lang.isEmpty {
            if let hit = tracks.first(where: { Self.language(of: $0) == lang }) { return hit }
        }
        return tracks.first(where: Self.isOriginal) ?? tracks[0]
    }

    /// The original voice: the server names it «Оригинал (English)».
    static func isOriginal(_ t: LiveTrack) -> Bool {
        [t.name, t.label].map { $0.lowercased() }.contains { $0.hasPrefix("оригинал") || $0.hasPrefix("original") }
    }

    /// The subtitles to show (nil: off) among `tracks` while `audio` plays: the viewer's
    /// pick by name, else by its language; else by the profile's `subMode`.
    public func subtitle(in tracks: [LiveTrack], audio: LiveTrack?, prefs: PlaybackPrefs) -> LiveTrack? {
        if let subtitle {
            guard let pick = subtitle else { return nil }
            if let hit = tracks.first(where: { $0.name == pick.name }) { return hit }
            let lang = Self.language(pick.lang)
            if !lang.isEmpty, let hit = tracks.first(where: { Self.language(of: $0) == lang }) { return hit }
        }
        guard !tracks.isEmpty else { return nil }
        let wanted: Bool
        switch prefs.subMode {
        case "always":
            wanted = true
        case "foreign":
            let lang = audio.map(Self.language(of:)) ?? ""
            wanted = !lang.isEmpty && !prefs.audioLangs.map(Self.language).contains(lang)
        default:
            wanted = false
        }
        guard wanted else { return nil }
        let langs = prefs.subLangs.isEmpty ? prefs.audioLangs : prefs.subLangs
        for lang in langs.map(Self.language) {
            if let hit = tracks.first(where: { Self.language(of: $0) == lang }) { return hit }
        }
        return nil
    }

    /// A track's two-letter language.
    static func language(of track: LiveTrack) -> String { language(track.lang) }

    static func language(_ tag: String) -> String { LiveRenditions.shortLang(tag) }
}
