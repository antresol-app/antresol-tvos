import Foundation

/// Turns what a user types ("192.168.1.10", "nas.local:8420", "https://media.example.com/")
/// into a server base URL.
public enum ServerAddress {
    public static let defaultPort = 8420

    /// Adds `http://` when no scheme is given and the default port when neither a scheme
    /// nor a port is given. Trailing slashes and a trailing `/api` are removed.
    public static func normalize(_ input: String) -> URL? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains(" ") else { return nil }
        let hasScheme = text.contains("://")
        if !hasScheme {
            text = "http://" + text
        }
        guard var components = URLComponents(string: text),
              let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = components.host, !host.isEmpty
        else { return nil }
        components.scheme = scheme
        if !hasScheme && components.port == nil {
            components.port = defaultPort
        }
        var path = components.path
        while path.hasSuffix("/") { path.removeLast() }
        if path.lowercased().hasSuffix("/api") { path.removeLast(4) }
        components.path = path
        components.query = nil
        components.fragment = nil
        return components.url
    }

    /// "host:port" (or host) for display.
    public static func displayName(_ url: URL) -> String {
        guard let host = url.host else { return url.absoluteString }
        if let port = url.port { return "\(host):\(port)" }
        return host
    }
}
