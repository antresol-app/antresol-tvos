import Foundation

/// The signed-in session as the Top Shelf extension needs it. The app writes it whenever
/// the profile, server or language changes and clears it on sign-out; the extension reads it.
///
/// The non-secret part (server, profile, language) is in the App Group's defaults; the
/// device token is in the shared Keychain access group.
struct SharedSession: Codable, Equatable {
    var serverURL: URL
    var userId: Int
    /// `en` or `ru`, sent as `Accept-Language`.
    var language: String
}

enum SharedSessionStore {
    /// App Group shared by the app and the Top Shelf extension.
    static let appGroup = "group.app.antresol.tv"

    private static let sessionKey = "shared.session"
    private static let tokenAccount = "session-token"

    /// The Keychain group, `<team prefix>app.antresol.shared`, from the `AntresolKeychainGroup`
    /// Info.plist key (the build expands the team prefix).
    private static var keychain: Keychain {
        let group = Bundle.main.object(forInfoDictionaryKey: "AntresolKeychainGroup") as? String
        return Keychain(service: "app.antresol.shared", accessGroup: group.flatMap { $0.isEmpty ? nil : $0 })
    }

    private static var defaults: UserDefaults? {
        UserDefaults(suiteName: appGroup)
    }

    /// Shared container for files both processes read (Top Shelf artwork).
    static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
    }

    static func load() -> (session: SharedSession, token: String)? {
        guard let data = defaults?.data(forKey: sessionKey),
              let session = try? JSONDecoder().decode(SharedSession.self, from: data),
              let token = keychain.string(for: tokenAccount)
        else { return nil }
        return (session, token)
    }

    /// Returns whether anything changed.
    @discardableResult
    static func save(_ session: SharedSession, token: String) -> Bool {
        if let current = load(), current.session == session, current.token == token {
            return false
        }
        try? keychain.set(token, for: tokenAccount)
        defaults?.set(try? JSONEncoder().encode(session), forKey: sessionKey)
        return true
    }

    /// Returns whether anything was stored before.
    @discardableResult
    static func clear() -> Bool {
        let hadSession = defaults?.data(forKey: sessionKey) != nil
        try? keychain.remove(tokenAccount)
        defaults?.removeObject(forKey: sessionKey)
        return hadSession
    }
}
