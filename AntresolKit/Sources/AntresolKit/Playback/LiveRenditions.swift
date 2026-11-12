import Foundation

/// An audio or subtitle rendition of a live master playlist (`EXT-X-MEDIA`),
/// in the master's order.
public struct HLSRendition: Equatable, Sendable {
    public enum Kind: String, Sendable { case audio = "AUDIO", subtitles = "SUBTITLES" }

    public var kind: Kind
    /// `NAME`: what the API's `audio[].name` / `subtitles[].name` refer to.
    public var name: String
    /// `LANGUAGE` (BCP 47), "" without one.
    public var language: String
    /// `URI` as written (`audio-3.m3u8?mk=…`).
    public var uri: String
    public var isDefault: Bool

    public init(kind: Kind, name: String, language: String = "", uri: String = "", isDefault: Bool = false) {
        self.kind = kind
        self.name = name
        self.language = language
        self.uri = uri
        self.isDefault = isDefault
    }
}

/// The renditions a channel's live master lists, and which AVFoundation
/// option is which of them.
///
/// Round 5 (spec «Every audio and subtitle track»): a run's master carries
/// up to 8 audio and 6 subtitle renditions with arbitrary names, in no fixed
/// order. The API's entries name them by `NAME`. AVFoundation does not
/// always hand that NAME back: an option's title metadata usually is the
/// NAME, but its `displayName` is made from the language («Английский» for
/// NAME="English"), and nothing on `AVMediaSelectionOption` exposes the URI.
/// So the player reads the master itself (it fetches index.m3u8 anyway while
/// the channel starts) and aligns the group's options with the master's
/// renditions of that kind:
///
/// 1. an option whose title is a rendition's NAME is that rendition;
/// 2. when the group has exactly the master's count and every option's
///    language agrees with the rendition at its place, the order is the
///    master's (AVFoundation lists HLS options in `EXT-X-MEDIA` order);
/// 3. otherwise, per language, the remaining options in group order are the
///    remaining renditions of that language in master order (the order
///    within one language is the one thing a reordering cannot scramble
///    without also renaming).
///
/// A name with no rendition (a key this run does not carry) falls back to
/// the first option of the entry's language.
public struct LiveRenditions: Equatable, Sendable {
    public var audio: [HLSRendition]
    public var subtitles: [HLSRendition]

    public init(audio: [HLSRendition] = [], subtitles: [HLSRendition] = []) {
        self.audio = audio
        self.subtitles = subtitles
    }

    public var isEmpty: Bool { audio.isEmpty && subtitles.isEmpty }

    /// Parses a master playlist (anything else gives none).
    public init(master: String) {
        var audio: [HLSRendition] = [], subtitles: [HLSRendition] = []
        for raw in master.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("#EXT-X-MEDIA:") else { continue }
            let attrs = Self.attributes(String(line.dropFirst("#EXT-X-MEDIA:".count)))
            guard let type = attrs["TYPE"].flatMap(HLSRendition.Kind.init(rawValue:)), let name = attrs["NAME"] else { continue }
            let r = HLSRendition(kind: type, name: name, language: attrs["LANGUAGE"] ?? "", uri: attrs["URI"] ?? "",
                                 isDefault: attrs["DEFAULT"] == "YES")
            if type == .audio { audio.append(r) } else { subtitles.append(r) }
        }
        self.init(audio: audio, subtitles: subtitles)
    }

    public init(master data: Data) {
        self.init(master: String(decoding: data, as: UTF8.self))
    }

    /// The attribute list of a tag: `KEY=VALUE` pairs, quoted values may hold commas.
    static func attributes(_ list: String) -> [String: String] {
        var out: [String: String] = [:]
        var key = "", value = "", inKey = true, quoted = false
        func flush() {
            let k = key.trimmingCharacters(in: .whitespaces)
            if !k.isEmpty { out[k] = value }
            key = ""; value = ""; inKey = true
        }
        for ch in list {
            if inKey {
                if ch == "=" { inKey = false } else if ch == "," { key = "" } else { key.append(ch) }
            } else if ch == "\"" {
                quoted.toggle()
            } else if ch == "," && !quoted {
                flush()
            } else {
                value.append(ch)
            }
        }
        if !inKey { flush() }
        return out
    }

    /// The two-letter form of a language tag ("rus" → "ru", "en-US" → "en").
    public static func shortLang(_ lang: String) -> String {
        let l = lang.lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init) ?? ""
        switch l {
        case "rus": return "ru"
        case "eng": return "en"
        case "fre", "fra": return "fr"
        case "ger", "deu": return "de"
        case "spa": return "es"
        case "ita": return "it"
        case "jpn": return "ja"
        case "ukr": return "uk"
        default: return l
        }
    }

    /// For each option (in group order): the index of its rendition in
    /// `renditions`, nil when it cannot be told.
    /// `options` are (title or display name, language tag).
    public static func align(options: [(name: String, lang: String)], renditions: [HLSRendition]) -> [Int?] {
        var map = [Int?](repeating: nil, count: options.count)
        guard !renditions.isEmpty else { return map }
        var taken = Set<Int>()
        // 1. by NAME, where the asset kept it
        for (i, o) in options.enumerated() {
            if let j = renditions.indices.first(where: { !taken.contains($0) && renditions[$0].name == o.name }) {
                map[i] = j
                taken.insert(j)
            }
        }
        // 2. the master's order, when the group is the master's and its languages line up
        if options.count == renditions.count, zip(options, renditions).allSatisfy({ o, r in
            let a = shortLang(o.lang), b = shortLang(r.language)
            return a.isEmpty || b.isEmpty || a == b
        }), map.enumerated().allSatisfy({ $1 == nil || $1 == $0 }) {
            return Array(renditions.indices).map(Optional.some)
        }
        // 3. per language, in order
        for (i, o) in options.enumerated() where map[i] == nil {
            let lang = shortLang(o.lang)
            if let j = renditions.indices.first(where: { !taken.contains($0) && shortLang(renditions[$0].language) == lang }) {
                map[i] = j
                taken.insert(j)
            }
        }
        return map
    }

    /// The option to select for the entry named `name` (language `lang`):
    /// the one aligned with the rendition of that NAME, else (no master, or
    /// no such rendition) an option titled `name`, else the first option of
    /// the language.
    public static func option(named name: String, lang: String, options: [(name: String, lang: String)],
                              renditions: [HLSRendition]) -> Int? {
        if let j = renditions.firstIndex(where: { $0.name == name }),
           let i = align(options: options, renditions: renditions).firstIndex(of: j) {
            return i
        }
        if let i = options.firstIndex(where: { $0.name == name }) { return i }
        let short = shortLang(lang)
        guard !short.isEmpty else { return nil }
        return options.firstIndex { shortLang($0.lang) == short }
    }

    /// The NAME of the rendition option `index` plays (nil: unknown).
    public static func name(ofOption index: Int, options: [(name: String, lang: String)], renditions: [HLSRendition]) -> String? {
        guard options.indices.contains(index) else { return nil }
        if let j = align(options: options, renditions: renditions)[index] { return renditions[j].name }
        return nil
    }
}
