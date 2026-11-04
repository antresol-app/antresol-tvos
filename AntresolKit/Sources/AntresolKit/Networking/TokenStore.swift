import Foundation

/// Identifies a stored device token: one per server and profile.
public struct CredentialKey: Hashable, Codable, Sendable {
    /// `serverId` from `/api/health`.
    public var serverId: String
    public var userId: Int

    public init(serverId: String, userId: Int) {
        self.serverId = serverId
        self.userId = userId
    }

    /// A stable account string for keychain-style stores.
    public var account: String {
        "\(serverId).\(userId)"
    }
}

/// Secure storage for device tokens. The tvOS app backs this with the Keychain.
public protocol TokenStore: Sendable {
    func token(for key: CredentialKey) -> String?
    func setToken(_ token: String, for key: CredentialKey) throws
    func removeToken(for key: CredentialKey) throws
}

/// A process-local store, for tests and previews.
public final class InMemoryTokenStore: TokenStore {
    private let tokens = Locked<[CredentialKey: String]>([:])

    public init() {}

    public func token(for key: CredentialKey) -> String? {
        tokens.withLock { $0[key] }
    }

    public func setToken(_ token: String, for key: CredentialKey) throws {
        tokens.withLock { $0[key] = token }
    }

    public func removeToken(for key: CredentialKey) throws {
        tokens.withLock { $0[key] = nil }
    }
}
