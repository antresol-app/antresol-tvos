import Foundation

/// The saved session: the server address lives in the Keychain next to the tokens, the
/// non-secret bits (server id, last profile) in `UserDefaults`.
struct AppSettings {
    private let defaults: UserDefaults
    private let keychain: Keychain

    init(defaults: UserDefaults = .standard, keychain: Keychain = Keychain(service: "app.antresol.tv.server")) {
        self.defaults = defaults
        self.keychain = keychain
    }

    private enum Key {
        static let serverURL = "server.url"
        static let serverId = "server.id"
        static let lastUserId = "profile.lastUserId"
    }

    var serverURL: URL? {
        get { keychain.string(for: Key.serverURL).flatMap(URL.init(string:)) }
        nonmutating set {
            if let newValue {
                try? keychain.set(newValue.absoluteString, for: Key.serverURL)
            } else {
                try? keychain.remove(Key.serverURL)
            }
        }
    }

    var serverId: String? {
        get { defaults.string(forKey: Key.serverId) }
        nonmutating set { defaults.set(newValue, forKey: Key.serverId) }
    }

    var lastUserId: Int? {
        get { defaults.object(forKey: Key.lastUserId) as? Int }
        nonmutating set { defaults.set(newValue, forKey: Key.lastUserId) }
    }
}
