import Foundation

/// LAN discovery of Antresol servers over DNS-SD (`_antresol._tcp`): what a TXT record
/// says and how a resolved address becomes a base URL. The browsing itself (NWBrowser)
/// lives in the app; this part is plain Foundation so it is tested everywhere.
public enum ServerDiscovery {
    /// The DNS-SD service type the server advertises (domain `local.`).
    public static let serviceType = "_antresol._tcp"

    /// The TXT keys of a server's advertisement (protocol version 1).
    public struct Advertisement: Hashable, Sendable {
        /// The server id, 32 lowercase hex characters (`serverId` of `/api/health`).
        public var id: String
        /// The display name (`VAULT_SERVER_NAME`).
        public var name: String
        public var version: String
        /// `http` today.
        public var scheme: String
        /// The HTTP port, when the TXT record names one (the SRV port otherwise).
        public var port: Int?
        /// The base path, "" for `/`.
        public var path: String
        public var txtVersion: Int

        public init(id: String, name: String, version: String = "", scheme: String = "http", port: Int? = nil, path: String = "", txtVersion: Int = 1) {
            self.id = id
            self.name = name
            self.version = version
            self.scheme = scheme
            self.port = port
            self.path = path
            self.txtVersion = txtVersion
        }
    }

    /// Reads a TXT record. Returns nil when it is not a usable Antresol advertisement: no
    /// valid `id`, or a scheme other than http/https. A newer `txtvers` is accepted as long
    /// as the keys this client needs are there. Keys are case-insensitive (RFC 6763 §6.4).
    public static func advertisement(fromTXT record: [String: String]) -> Advertisement? {
        var keys: [String: String] = [:]
        for (key, value) in record {
            keys[key.lowercased()] = value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let id = keys["id"]?.lowercased(), isServerID(id) else { return nil }
        let scheme = (keys["scheme"].flatMap { $0.isEmpty ? nil : $0 } ?? "http").lowercased()
        guard scheme == "http" || scheme == "https" else { return nil }
        let port = keys["port"].flatMap(Int.init).flatMap { (1...65535).contains($0) ? $0 : nil }
        var path = keys["path"] ?? ""
        while path.hasSuffix("/") { path.removeLast() }
        if !path.isEmpty && !path.hasPrefix("/") { path = "/" + path }
        let name = keys["name"].flatMap { $0.isEmpty ? nil : $0 } ?? "Antresol"
        return Advertisement(
            id: id, name: name, version: keys["version"] ?? "", scheme: scheme, port: port, path: path,
            txtVersion: keys["txtvers"].flatMap(Int.init) ?? 1
        )
    }

    /// Whether `text` is a server id: 32 lowercase hex characters.
    public static func isServerID(_ text: String) -> Bool {
        text.count == 32 && text.allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) }
    }

    /// `<scheme>://<host>:<port><path>` for a resolved address. The TXT `port` wins over the
    /// SRV port (they are the same today). IPv6 literals are bracketed, a zone id dropped.
    public static func baseURL(host: String, port: Int, advertisement: Advertisement) -> URL? {
        var host = host.trimmingCharacters(in: .whitespaces)
        if let percent = host.firstIndex(of: "%") { host = String(host[..<percent]) }
        guard !host.isEmpty else { return nil }
        if host.contains(":") && !host.hasPrefix("[") { host = "[\(host)]" }
        let port = advertisement.port ?? port
        guard (1...65535).contains(port) else { return nil }
        return URL(string: "\(advertisement.scheme)://\(host):\(port)\(advertisement.path)")
    }
}

/// A server found on the LAN and confirmed with `/api/health` (same `serverId`).
public struct DiscoveredServer: Hashable, Identifiable, Sendable {
    /// The server id.
    public var id: String
    public var name: String
    /// The version `/api/health` reported (the TXT one before that).
    public var version: String
    public var baseURL: URL

    public init(id: String, name: String, version: String, baseURL: URL) {
        self.id = id
        self.name = name
        self.version = version
        self.baseURL = baseURL
    }

    /// "192.168.1.10:8420" for display.
    public var address: String { ServerAddress.displayName(baseURL) }

    /// The list a screen shows: one entry per server id (the latest wins), by name, then
    /// address.
    public static func merged(_ servers: [DiscoveredServer]) -> [DiscoveredServer] {
        var byID: [String: DiscoveredServer] = [:]
        for server in servers { byID[server.id] = server }
        return byID.values.sorted {
            let order = $0.name.localizedCaseInsensitiveCompare($1.name)
            return order == .orderedSame ? $0.address < $1.address : order == .orderedAscending
        }
    }
}
