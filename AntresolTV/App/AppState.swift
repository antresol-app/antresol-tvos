import AntresolKit
import Foundation
import Observation

/// App-wide session state: which server we talk to and who is signed in.
@MainActor
@Observable
final class AppState {
    enum Phase: Equatable {
        /// Restoring the saved server and token.
        case launching
        /// No server configured yet.
        case needsServer
        /// The saved server did not answer.
        case serverUnreachable(message: String)
        /// Connected; a profile has to be picked (and its password entered).
        case needsProfile
        /// A profile is signed in.
        case signedIn(User)
    }

    private(set) var phase: Phase = .launching
    /// The connected server, once known.
    private(set) var server: ServerConnection?

    private let settings: AppSettings
    private let tokens: TokenStore
    private let device: DeviceIdentity

    init(settings: AppSettings = AppSettings(), tokens: TokenStore = KeychainTokenStore(), device: DeviceIdentity = DeviceIdentity()) {
        self.settings = settings
        self.tokens = tokens
        self.device = device
    }

    var client: APIClient? { server?.client }

    var currentUser: User? {
        if case .signedIn(let user) = phase { return user }
        return nil
    }

    /// Restores the saved server and profile, validating the stored token with `/api/me`.
    func bootstrap() async {
        guard phase == .launching || isUnreachable else { return }
        phase = .launching
        guard let url = settings.serverURL else {
            phase = .needsServer
            return
        }
        do {
            let connection = try await ServerConnection.connect(to: url, language: Self.preferredLanguage)
            server = connection
            settings.serverId = connection.serverId
            await restoreProfile(on: connection)
        } catch {
            phase = .serverUnreachable(message: error.localizedDescription)
        }
    }

    /// Validates a user-entered address and makes it the current server.
    func connect(to address: String) async throws {
        guard let url = ServerAddress.normalize(address) else {
            throw APIError.invalidURL(address)
        }
        let connection = try await ServerConnection.connect(to: url, language: Self.preferredLanguage)
        settings.serverURL = url
        settings.serverId = connection.serverId
        server = connection
        await restoreProfile(on: connection)
    }

    /// Signs in to a profile; the token is kept in the Keychain per server and profile.
    func signIn(profile: Profile, password: String?) async throws {
        guard let server else { return }
        let response = try await server.client.signIn(userId: profile.id, password: password, device: device.info)
        try tokens.setToken(response.token, for: CredentialKey(serverId: server.serverId, userId: profile.id))
        settings.lastUserId = profile.id
        phase = .signedIn(response.user)
    }

    /// Returns to the profile picker, keeping the current profile's token for later.
    func switchProfile() {
        guard let server else { return }
        server.client.token = nil
        settings.lastUserId = nil
        phase = .needsProfile
    }

    /// Revokes the current token on the server and forgets it.
    func signOut() async {
        guard let server, let user = currentUser else { return }
        try? await server.client.signOut()
        try? tokens.removeToken(for: CredentialKey(serverId: server.serverId, userId: user.id))
        settings.lastUserId = nil
        phase = .needsProfile
    }

    /// Called when any request reports `401`: the token was revoked.
    func handleUnauthorized() {
        guard let server, let user = currentUser else { return }
        try? tokens.removeToken(for: CredentialKey(serverId: server.serverId, userId: user.id))
        server.client.token = nil
        phase = .needsProfile
    }

    private var isUnreachable: Bool {
        if case .serverUnreachable = phase { return true }
        return false
    }

    private func restoreProfile(on connection: ServerConnection) async {
        guard let userId = settings.lastUserId,
              let token = tokens.token(for: CredentialKey(serverId: connection.serverId, userId: userId))
        else {
            phase = .needsProfile
            return
        }
        connection.client.token = token
        do {
            phase = .signedIn(try await connection.client.me())
        } catch let error as APIError where error.statusCode == 401 {
            try? tokens.removeToken(for: CredentialKey(serverId: connection.serverId, userId: userId))
            connection.client.token = nil
            phase = .needsProfile
        } catch {
            phase = .serverUnreachable(message: error.localizedDescription)
        }
    }

    /// `en` or `ru`, from the user's preferred languages.
    static var preferredLanguage: String {
        APIClient.normalizeLanguage(Locale.preferredLanguages.first ?? "en")
    }
}

/// A server that answered `/api/health`.
struct ServerConnection {
    let client: APIClient
    let serverId: String
    let version: String

    static func connect(to url: URL, language: String) async throws -> ServerConnection {
        let client = APIClient(baseURL: url, language: language)
        let health = try await client.health()
        return ServerConnection(client: client, serverId: health.serverId, version: health.version)
    }
}
