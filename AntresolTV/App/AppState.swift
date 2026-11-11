import AntresolKit
import Foundation
import Observation
import TVServices

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

    private(set) var phase: Phase = .launching {
        didSet { publishSharedSession() }
    }
    /// The app language; changing it also changes the language the server answers in.
    var language: AppLanguage = .stored {
        didSet {
            guard language != oldValue else { return }
            language.persist()
            server?.client.language = language.serverCode
            profileClient?.language = language.serverCode
            publishSharedSession()
        }
    }
    /// A link (Top Shelf, URL scheme) waiting for the signed-in shell to open it.
    var pendingDeepLink: DeepLink?
    /// A short message for the shell's banner (a failed action outside a page that can
    /// show it). Cleared after a few seconds.
    private(set) var notice: String?
    @ObservationIgnored private var noticeTask: Task<Void, Never>?
    /// Grows when the profile's library state changed (watchlist), so Home reloads its
    /// shelves.
    private(set) var libraryRevision = 0
    /// The connected server, once known. Its client never carries a token: it serves
    /// the profile picker and sign-in.
    private(set) var server: ServerConnection?
    /// The signed-in profile's client. Each profile gets its own client with a fixed token,
    /// so requests still in flight when the profile changes (final progress writes,
    /// scrobbles) finish with the token they started with and never leak into the next one.
    private var profileClient: APIClient?
    /// Where "Cancel" on the server screen returns to.
    private var phaseBeforeServerChange: Phase?

    private let settings: AppSettings
    private let tokens: TokenStore
    private let device: DeviceIdentity

    init(settings: AppSettings = AppSettings(), tokens: TokenStore = KeychainTokenStore(), device: DeviceIdentity = DeviceIdentity()) {
        self.settings = settings
        self.tokens = tokens
        self.device = device
        AppLanguage.captureSystemLanguage()
    }

    /// The signed-in profile's client, or the server's anonymous one before sign-in.
    var client: APIClient? { profileClient ?? server?.client }

    var currentUser: User? {
        if case .signedIn(let user) = phase { return user }
        return nil
    }

    /// Restores the saved server and profile, validating the stored token with `/api/me`.
    func bootstrap() async {
        guard phase == .launching || isUnreachable else { return }
        phase = .launching
        #if DEBUG
        applyLaunchOverrides()
        #endif
        guard let url = settings.serverURL else {
            phase = .needsServer
            return
        }
        do {
            let connection = try await ServerConnection.connect(to: url, language: language.serverCode)
            server = connection
            settings.serverId = connection.serverId
            await restoreProfile(on: connection)
        } catch {
            phase = .serverUnreachable(message: Self.userMessage(for: error))
        }
    }

    /// Validates a user-entered address with `/api/health` and makes it the current server.
    /// Accepts a host, `host:port` or a full http(s) URL; the port defaults to 8420.
    func connect(to address: String) async throws {
        guard let url = ServerAddress.normalize(address) else {
            throw APIError.invalidURL(address)
        }
        let connection = try await ServerConnection.connect(to: url, language: language.serverCode)
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
            let candidate = server.profileClient(token: token)
            do {
                let user = try await candidate.me()
                profileClient = candidate
                settings.lastUserId = profile.id
                phase = .signedIn(user)
                return .signedIn
            } catch let error as APIError where error.statusCode == 401 {
                try? tokens.removeToken(for: key)
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
        profileClient = server.profileClient(token: response.token)
        settings.lastUserId = profile.id
        phase = .signedIn(response.user)
    }

    /// Returns to the profile picker, keeping the current profile's token for later.
    func switchProfile() {
        guard server != nil else { return }
        leaveProfile()
    }

    /// Revokes the current token on the server and forgets it.
    func signOut() async {
        guard let server, let user = currentUser, let profileClient else { return }
        try? await profileClient.signOut()
        try? tokens.removeToken(for: CredentialKey(serverId: server.serverId, userId: user.id))
        leaveProfile()
    }

    /// Called when any request reports `401`: the token was revoked.
    func handleUnauthorized() {
        guard let server, let user = currentUser else { return }
        try? tokens.removeToken(for: CredentialKey(serverId: server.serverId, userId: user.id))
        leaveProfile()
    }

    private func leaveProfile() {
        profileClient = nil
        settings.lastUserId = nil
        phase = .needsProfile
    }

    /// Shows `message` in the shell's banner for a few seconds.
    func showNotice(_ message: String) {
        noticeTask?.cancel()
        notice = message
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.notice = nil
        }
    }

    /// Records a change to the profile's library state (for example the watchlist).
    func libraryChanged() {
        libraryRevision += 1
    }

    /// Routes a failed request: `401` signs the profile out to the picker and returns
    /// nil; anything else returns a message to show.
    func message(for error: Error) -> String? {
        if let error = error as? APIError, error.statusCode == 401 {
            handleUnauthorized()
            return nil
        }
        return Self.userMessage(for: error)
    }

    /// A localized, non-technical description of a failure: the server's own message
    /// when it sent one (in the app language), otherwise a plain explanation.
    static func userMessage(for error: Error) -> String {
        if let error = error as? APIError {
            switch error {
            case .unauthorized(let message):
                return message ?? String(localized: "Sign in again to continue.", bundle: .localized)
            case .server(let status, let message, _, _):
                if let message, !message.isEmpty { return message }
                if status == 404 { return String(localized: "This item is no longer in the library.", bundle: .localized) }
                if status >= 500 { return String(localized: "The server had a problem. Try again in a moment.", bundle: .localized) }
                return String(localized: "The server couldn't complete the request.", bundle: .localized)
            case .decoding:
                return String(localized: "Unexpected response from the server.", bundle: .localized)
            case .transport:
                return String(localized: "Couldn't reach the server. Check that it is running and on the same network.", bundle: .localized)
            case .invalidURL:
                return String(localized: "That doesn't look like a server address.", bundle: .localized)
            }
        }
        if error is URLError {
            return String(localized: "Couldn't reach the server. Check that it is running and on the same network.", bundle: .localized)
        }
        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            return description
        }
        return String(localized: "Something went wrong. Try again.", bundle: .localized)
    }

    #if DEBUG
    /// UI-test hooks, passed as launch arguments (`-AntresolResetSession YES`,
    /// `-AntresolServerURL <address>`, `-AntresolOpenURL <antresol://…>`): start from a clean
    /// session and/or a given server, and open a link once signed in.
    private func applyLaunchOverrides() {
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: "AntresolResetSession") {
            settings.serverURL = nil
            settings.lastUserId = nil
        }
        if let address = defaults.string(forKey: "AntresolServerURL"), let url = ServerAddress.normalize(address) {
            settings.serverURL = url
        }
        if let link = defaults.string(forKey: "AntresolOpenURL").flatMap(URL.init(string:)) {
            open(link)
        }
    }
    #endif

    private var isUnreachable: Bool {
        if case .serverUnreachable = phase { return true }
        return false
    }

    private func restoreProfile(on connection: ServerConnection) async {
        guard let userId = settings.lastUserId,
              let token = tokens.token(for: CredentialKey(serverId: connection.serverId, userId: userId))
        else {
            profileClient = nil
            phase = .needsProfile
            return
        }
        let candidate = connection.profileClient(token: token)
        do {
            let user = try await candidate.me()
            profileClient = candidate
            phase = .signedIn(user)
        } catch let error as APIError where error.statusCode == 401 {
            try? tokens.removeToken(for: CredentialKey(serverId: connection.serverId, userId: userId))
            profileClient = nil
            phase = .needsProfile
        } catch {
            profileClient = nil
            phase = .serverUnreachable(message: Self.userMessage(for: error))
        }
    }

    /// Opens an `antresol://` URL once a profile is signed in.
    func open(_ url: URL) {
        if let link = DeepLink(url: url) {
            pendingDeepLink = link
        }
    }

    /// Shares the signed-in session with the Top Shelf extension (or clears it) and asks
    /// the system to reload the Top Shelf when that changed.
    private func publishSharedSession() {
        let changed: Bool
        if case .signedIn(let user) = phase, let server, let token = profileClient?.token {
            let session = SharedSession(serverURL: server.url, userId: user.id, language: language.serverCode)
            changed = SharedSessionStore.save(session, token: token)
        } else {
            changed = SharedSessionStore.clear()
        }
        if changed {
            TVTopShelfContentProvider.topShelfContentDidChange()
        }
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

    /// A client for one signed-in profile on this server.
    func profileClient(token: String) -> APIClient {
        APIClient(baseURL: client.baseURL, token: token, language: client.language)
    }

    static func connect(to url: URL, language: String) async throws -> ServerConnection {
        let client = APIClient(baseURL: url, language: language)
        let health = try await client.health()
        return ServerConnection(client: client, serverId: health.serverId, version: health.version)
    }
}
