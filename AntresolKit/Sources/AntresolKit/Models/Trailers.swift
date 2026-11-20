import Foundation

/// A trailer or teaser of a movie or series (`GET /api/items/{id}/trailers`): a TMDB video
/// on YouTube. The server orders them for the viewer (their language first, then English;
/// official ones first; trailers before teasers).
public struct Trailer: Decodable, Hashable, Identifiable, Sendable {
    public var name: String
    /// "YouTube" (the server lists nothing else).
    public var site: String
    /// The YouTube video id.
    public var key: String
    /// "Trailer" or "Teaser".
    public var type: String
    /// Two-letter language code, or `""`.
    public var lang: String
    public var official: Bool
    /// The https watch page, for a phone or a browser.
    public var url: String
    /// `POST` here to play the trailer in the app (`/api/trailers/<key>/play`). nil when the
    /// server cannot fetch trailers (an older server, or trailers turned off): the app then
    /// falls back to the trailer site.
    public var play: String?

    public var id: String { key }

    public init(name: String, site: String = "YouTube", key: String, type: String = "Trailer", lang: String = "", official: Bool = false, url: String = "", play: String? = nil) {
        self.name = name
        self.site = site
        self.key = key
        self.type = type
        self.lang = lang
        self.official = official
        self.url = url
        self.play = play
    }

    enum CodingKeys: String, CodingKey { case name, site, key, type, lang, official, url, play }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = try c.decode(String.self, forKey: .key)
        name = c.value(.name, default: "")
        site = c.value(.site, default: "YouTube")
        type = c.value(.type, default: "Trailer")
        lang = c.value(.lang, default: "")
        official = c.value(.official, default: false)
        url = c.value(.url, default: "")
        play = Self.playPath(c.optional(.play))
    }

    /// Whether the server plays this trailer itself (`play` is set).
    public var playsInApp: Bool { play != nil }

    /// Only a server path under `/api/trailers/` is kept: the app never posts elsewhere.
    static func playPath(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespaces), value.hasPrefix("/api/trailers/"),
              !value.contains(".."), !value.contains("?"), !value.contains("#") else { return nil }
        return value
    }

    /// Whether it is a teaser rather than a full trailer.
    public var isTeaser: Bool {
        type.caseInsensitiveCompare("Teaser") == .orderedSame
    }

    /// The YouTube app's link to the video (`youtube://watch/<key>`).
    public var appURL: URL? {
        guard !key.isEmpty, let escaped = key.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else { return nil }
        return URL(string: "youtube://watch/\(escaped)")
    }

    /// The https watch page: the server's `url`, else built from the key.
    public var webURL: URL? {
        if let url = URL(string: url), url.scheme?.lowercased() == "https" { return url }
        guard !key.isEmpty else { return nil }
        var components = URLComponents(string: "https://www.youtube.com/watch")
        components?.queryItems = [URLQueryItem(name: "v", value: key)]
        return components?.url
    }
}

/// `{"trailers": [...]}`.
public struct TrailerList: Decodable, Sendable {
    /// How many trailers a page offers, best first: the web's «Ещё» menu lists the best three.
    public static let maxOffered = 3

    public var trailers: [Trailer]

    public init(trailers: [Trailer]) {
        self.trailers = trailers
    }

    enum CodingKeys: String, CodingKey { case trailers }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // A malformed entry (no key) drops that entry only.
        let entries: [Lenient<Trailer>] = c.value(.trailers, default: [])
        trailers = entries.compactMap(\.value).filter { !$0.key.isEmpty && $0.site.caseInsensitiveCompare("YouTube") == .orderedSame }
    }
}

/// Decodes one array element, or nil when it does not decode.
struct Lenient<T: Decodable>: Decodable {
    let value: T?

    init(from decoder: Decoder) throws {
        value = try? T(from: decoder)
    }
}
