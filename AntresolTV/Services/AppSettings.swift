import Foundation

/// Non-secret preferences persisted in `UserDefaults`. Tokens live in the Keychain.
struct AppSettings {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private enum Key {
        static let serverURL = "server.url"
        static let serverId = "server.id"
        static let lastUserId = "profile.lastUserId"
    }

    var serverURL: URL? {
        get { defaults.string(forKey: Key.serverURL).flatMap(URL.init(string:)) }
        nonmutating set { defaults.set(newValue?.absoluteString, forKey: Key.serverURL) }
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
