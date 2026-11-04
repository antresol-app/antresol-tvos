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
        /// No server configured yet, or the user asked to change it.
        case needsServer
        /// The saved server did not answer.
        case serverUnreachable(message: String)
        /// Connected; a profile has to be picked (and its password entered).
        case needsProfile
        /// A profile is signed in.
        case signedIn(User)
    }

    /// What picking a profile led to.
    enum ProfileSelection {
        case signedIn
        /// The profile is protected; ask for its password and call `signIn`.
        case needsPassword
    }

    private(set) var phase: Phase = .launching
    /// The connected server, once known.
    private(set) var server: ServerConnection?
    /// Where "Cancel" on the server screen returns to.
    private var phaseBeforeServerChange: Phase?

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

    /// Validates a user-entered address with `/api/health` and makes it the current server.
    /// Accepts a host, `host:port` or a full http(s) URL; the port defaults to 8420.
    func connect(to address: String) async throws {
        guard let url = ServerAddress.normalize(address) else {
            throw APIError.invalidURL(address)
        }
        let connection = try await ServerConnection.connect(to: url, language: Self.preferredLanguage)
        if connection.serverId != server?.serverId {
            settings.lastUserId = nil
        }
        settings.serverURL = url
        settings.serverId = connection.serverId
        server = connection
        phaseBeforeServerChange = nil
        await restoreProfile(on: connection)
    }

    /// Shows the server address screen. The current session stays as it is until another
    /// server connects, so the user can go back.
    func changeServer() {
        phaseBeforeServerChange = phase
        phase = .needsServer
    }

    /// Whether the server screen was opened from a running session and can be dismissed.
    var canCancelServerChange: Bool {
        phaseBeforeServerChange != nil
    }

    /// Leaves the server screen without changing anything.
    func cancelServerChange() {
        guard let previous = phaseBeforeServerChange else { return }
        phaseBeforeServerChange = nil
        phase = previous
    }

    /// Picks a profile on the picker. Passwordless profiles reuse their stored token when it
    /// is still valid, or sign in directly. Protected profiles always ask for the password,
    /// so a stored token never lets someone else walk into a protected profile.
    func selectProfile(_ profile: Profile) async throws -> ProfileSelection {
        guard let server else { throw APIError.invalidURL("") }
        if profile.hasPassword {
            return .needsPassword
        }
        let key = CredentialKey(serverId: server.serverId, userId: profile.id)
        if let token = tokens.token(for: key) {
            server.client.token = token
            do {
                let user = try await server.client.me()
                settings.lastUserId = profile.id
                phase = .signedIn(user)
                return .signedIn
            } catch let error as APIError where error.statusCode == 401 {
                try? tokens.removeToken(for: key)
                server.client.token = nil
            }
        }
        try await signIn(profile: profile, password: nil)
        return .signedIn
    }

    /// Requests a device token for a profile; it is kept in the Keychain per server and profile.
    func signIn(profile: Profile, password: String?) async throws {
        guard let server else { throw APIError.invalidURL("") }
        let response = try await server.client.signIn(userId: profile.id, password: password, device: device.info)
        try tokens.setToken(response.token, for: CredentialKey(serverId: server.serverId, userId: profile.id))
        server.client.token = response.token
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
        server.client.token = nil
        settings.lastUserId = nil
        phase = .needsProfile
    }

    /// Called when any request reports `401`: the token was revoked.
    func handleUnauthorized() {
        guard let server, let user = currentUser else { return }
        try? tokens.removeToken(for: CredentialKey(serverId: server.serverId, userId: user.id))
        server.client.token = nil
        settings.lastUserId = nil
        phase = .needsProfile
    }

    /// Routes a failed request: `401` signs the profile out to the picker and returns
    /// nil; anything else returns a message to show.
    func message(for error: Error) -> String? {
        if let error = error as? APIError, error.statusCode == 401 {
            handleUnauthorized()
            return nil
        }
        return error.localizedDescription
    }

    private var isUnreachable: Bool {
        if case .serverUnreachable = phase { return true }
        return false
    }

    private func restoreProfile(on connection: ServerConnection) async {
        guard let userId = settings.lastUserId,
              let token = tokens.token(for: CredentialKey(serverId: connection.serverId, userId: userId))
        else {
            connection.client.token = nil
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

    var url: URL { client.baseURL }

    /// "host:port" for display.
    var displayName: String { ServerAddress.displayName(client.baseURL) }

    static func connect(to url: URL, language: String) async throws -> ServerConnection {
        let client = APIClient(baseURL: url, language: language)
        let health = try await client.health()
        return ServerConnection(client: client, serverId: health.serverId, version: health.version)
    }
}
