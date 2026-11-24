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

    /// The URLs to try for what was typed, best first. An address without a scheme for a
    /// host away from the home network is tried over https first (the port, when one was
    /// typed, goes with it), and over plain http (`normalize`) only after that; every other
    /// address is the one URL `normalize` makes of it. Empty for something that is not an
    /// address.
    public static func candidates(for input: String) -> [URL] {
        guard let plain = normalize(input) else { return [] }
        guard !input.contains("://"), isUnencryptedRemote(plain),
              var secure = URLComponents(url: plain, resolvingAgainstBaseURL: false)
        else { return [plain] }
        secure.scheme = "https"
        if secure.port == defaultPort { secure.port = nil }
        return [secure.url, plain].compactMap { $0 }
    }

    /// Plain http to a host away from the home network: what is sent there (the profile's
    /// password) crosses the internet in the clear.
    public static func isUnencryptedRemote(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "http" && !(url.host.map(isHomeNetwork) ?? true)
    }

    /// Whether `host` is on the home network (or a VPN's): a private or link-local IP
    /// address, a name `.local`, `.lan`, `.home`, `.internal` or without a dot (a router's
    /// own name for a device), or a carrier-grade NAT address (100.64/10: Tailscale).
    static func isHomeNetwork(_ host: String) -> Bool {
        let name = host.lowercased()
        if LocalAddress.isPrivate(name) { return true }
        if let v4 = LocalAddress.ipv4(name) { return v4[0] == 100 && (64...127).contains(v4[1]) }
        if name.contains(":") { return false }
        return !name.contains(".") || [".local", ".lan", ".home", ".internal"].contains { name.hasSuffix($0) }
    }

    /// "host:port" (or host) for display.
    public static func displayName(_ url: URL) -> String {
        guard let host = url.host else { return url.absoluteString }
        if let port = url.port { return "\(host):\(port)" }
        return host
    }
}
