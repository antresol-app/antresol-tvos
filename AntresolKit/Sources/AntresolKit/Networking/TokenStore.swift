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
