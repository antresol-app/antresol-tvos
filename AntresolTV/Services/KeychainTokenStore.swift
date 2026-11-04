import AntresolKit
import Foundation

/// Stores device tokens as generic passwords in the Keychain, one per server and profile.
final class KeychainTokenStore: TokenStore {
    private let keychain: Keychain

    init(service: String = "app.antresol.tv.device-token") {
        keychain = Keychain(service: service)
    }

    func token(for key: CredentialKey) -> String? {
        keychain.string(for: key.account)
    }

    func setToken(_ token: String, for key: CredentialKey) throws {
        try keychain.set(token, for: key.account)
    }

    func removeToken(for key: CredentialKey) throws {
        try keychain.remove(key.account)
    }
}
