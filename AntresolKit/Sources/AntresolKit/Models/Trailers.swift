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

    public var id: String { key }

    public init(name: String, site: String = "YouTube", key: String, type: String = "Trailer", lang: String = "", official: Bool = false, url: String = "") {
        self.name = name
        self.site = site
        self.key = key
        self.type = type
        self.lang = lang
        self.official = official
        self.url = url
    }

    enum CodingKeys: String, CodingKey { case name, site, key, type, lang, official, url }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = try c.decode(String.self, forKey: .key)
        name = c.value(.name, default: "")
        site = c.value(.site, default: "YouTube")
        type = c.value(.type, default: "Trailer")
        lang = c.value(.lang, default: "")
        official = c.value(.official, default: false)
        url = c.value(.url, default: "")
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
