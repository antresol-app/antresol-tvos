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

    /// How the sign-in screen signs a profile in.
    enum SignInMethod: Equatable {
        /// A QR code a signed-in phone approves (the default on a new server).
        case phone
        /// The profile picker and the password, with the remote.
        case remote
    }

    /// What picking a profile led to.
    enum ProfileSelection {
        case signedIn
        /// The profile is protected; ask for its password and call `signIn`.
        case needsPassword
    }

    private(set) var phase: Phase = .launching {
        didSet {
            publishSharedSession()
            if case .signedIn = phase { Task { await refreshInterfaceLanguage() } }
        }
    }
    /// The profile's interface language as the server keeps it (`GET /api/me/ui-language`):
    /// its `effective` language runs the whole interface — strings, 24-hour time for
    /// Russian, and `Accept-Language` of every request; "" follows the device.
    private(set) var interfaceLanguage: UILanguage?
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
    /// The profile's channel-list choices (`GET /api/channels/prefs`); nil until read or on
    /// a server without them (Settings then has no row).
    private(set) var channelPrefs: ChannelPrefs?
    /// Goes up when `channelPrefs` changed here: the TV page fetches its list again (the
    /// server orders it).
    private(set) var channelPrefsRevision = 0
    /// A link (Top Shelf, URL scheme) waiting for the signed-in shell to open it.
    var pendingDeepLink: DeepLink?
    /// A short message for the shell's banner (a failed action outside a page that can
    /// show it). Cleared after a few seconds.
    var notice: String? { timedNotice.message }
    @ObservationIgnored private let timedNotice = TimedNotice()
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
    /// «Switch Profile» opened the picker over this live session: its client, its stored
    /// token and `lastUserId` stay, and its shell stays alive under the picker (`RootView`),
    /// so Menu (or picking it again) returns to where the user was.
    private(set) var profileSwitch: ProfileSwitch?
    /// The `/api/me` check of a 401 now running.
    @ObservationIgnored private var sessionCheck: Task<Void, Never>?
    /// The sign-in screen's method: the QR code first, the profile picker after
    /// "Sign in with the remote" (and after Switch Profile, where the household is at the TV).
    var signInMethod: SignInMethod = .phone
    /// The connected server has QR sign-in (`POST /api/auth/pair/start` exists); an older
    /// one shows the profile picker only.
    private(set) var supportsPairing = true
    /// A sign-in code started by a phone setup, waiting for the sign-in screen.
    @ObservationIgnored private var pendingPairingTicket: PairingTicket?

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

    /// Whose shell is alive: the signed-in profile, or the one «Switch Profile» was opened over.
    var shellUser: User? {
        currentUser ?? (phase == .needsProfile ? profileSwitch?.from : nil)
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
    /// Accepts a host, `host:port` or a full http(s) URL; the port defaults to 8420. A host
    /// away from the home network typed without a scheme is tried over https first. Plain
    /// http to such a host (typed, or after https failed) needs `allowUnencrypted`: without
    /// it the call throws `UnencryptedConnection` before anything is sent or kept.
    func connect(to address: String, allowUnencrypted: Bool = false) async throws {
        var failure: Error = APIError.invalidURL(address)
        var reached: (url: URL, connection: ServerConnection)?
        for url in ServerAddress.candidates(for: address) {
            if ServerAddress.isUnencryptedRemote(url), !allowUnencrypted { throw UnencryptedConnection() }
            do {
                reached = (url, try await ServerConnection.connect(to: url, language: language.serverCode))
                break
            } catch {
                failure = error
            }
        }
        guard let (url, connection) = reached else { throw failure }
        if connection.serverId != server?.serverId {
            settings.lastUserId = nil
        }
        settings.serverURL = url
        settings.serverId = connection.serverId
        server = connection
        supportsPairing = true
        signInMethod = .phone
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
        // The profile «Switch Profile» was opened from: straight back, no password.
        if profileSwitch?.returnsToCurrent(picking: profile.id) == true {
            cancelSwitch()
            return .signedIn
        }
        if profile.hasPassword {
            return .needsPassword
        }
        let key = CredentialKey(serverId: server.serverId, userId: profile.id)
        if let token = tokens.token(for: key) {
            let candidate = server.profileClient(token: token)
            do {
                let user = try await candidate.me()
                let left = takeSwitch()
                profileClient = candidate
                settings.lastUserId = profile.id
                phase = .signedIn(user)
                retire(left, signedInAs: user.id)
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
        let left = takeSwitch()
        profileClient = server.profileClient(token: response.token)
        settings.lastUserId = profile.id
        phase = .signedIn(response.user)
        retire(left, signedInAs: response.user.id)
    }

    /// Finishes a QR sign-in: the token a phone approved is a normal device token, kept
    /// like one from the password sign-in.
    func signIn(pairedToken token: String, user: User) throws {
        guard let server else { throw APIError.invalidURL("") }
        try tokens.setToken(token, for: CredentialKey(serverId: server.serverId, userId: user.id))
        let left = takeSwitch()
        profileClient = server.profileClient(token: token)
        settings.lastUserId = user.id
        phase = .signedIn(user)
        retire(left, signedInAs: user.id)
    }

    /// Ends a pending «Switch Profile» because another profile is signing in: its session (to retire).
    private func takeSwitch() -> (change: ProfileSwitch, client: APIClient?)? {
        guard let change = profileSwitch else { return nil }
        profileSwitch = nil
        return (change, profileClient)
    }

    /// After another profile signed in from «Switch Profile»: a password profile's token is
    /// revoked with its own Bearer and forgotten; a passwordless one stays for a quick switch back.
    private func retire(_ left: (change: ProfileSwitch, client: APIClient?)?, signedInAs userId: Int) {
        guard let left, left.change.revokesLeftToken(signedInAs: userId), let server else { return }
        try? tokens.removeToken(for: CredentialKey(serverId: server.serverId, userId: left.change.from.id))
        if let client = left.client {
            Task { try? await client.signOut() }
        }
    }

    /// Set up from a phone (`POST /setup` on this TV): checks `url` with `/api/health`
    /// (and that it is the server `serverId` names, when the phone sent one), starts QR
    /// sign-in on it, then saves it as this TV's server, as a typed address would be, and
    /// shows the sign-in screen with that code; the phone approves it next. Throws
    /// `TVSetupFailure`; nothing changes on a failure.
    func setUpFromPhone(server url: URL, serverId: String?) async throws -> TVSetupAnswer {
        let connection: ServerConnection
        do {
            connection = try await ServerConnection.connect(to: url, language: language.serverCode)
        } catch {
            throw TVSetupFailure.classify(error)
        }
        guard !connection.serverId.isEmpty else { throw TVSetupFailure.notAntresol }
        if let serverId, serverId.lowercased() != connection.serverId.lowercased() {
            throw TVSetupFailure.serverMismatch
        }
        // A fresh server without profiles: nobody could approve the sign-in.
        if let status = try? await connection.client.setupStatus(), status.needsSetup {
            throw TVSetupFailure.notSetUp
        }
        let ticket: PairingTicket
        do {
            ticket = try await connection.client.pairStart(device: device.info)
        } catch let error as APIError where error.statusCode == 404 || error.statusCode == 405 {
            // An Antresol server older than QR sign-in: keep it, the picker is the way in.
            adopt(connection, url: url)
            pairingUnsupported()
            phase = .needsProfile
            throw TVSetupFailure.pairingUnsupported
        } catch {
            throw TVSetupFailure.classify(error)
        }
        adopt(connection, url: url)
        pendingPairingTicket = ticket
        phase = .needsProfile
        return TVSetupAnswer(code: ticket.code, sid: ticket.serverId.isEmpty ? connection.serverId : ticket.serverId,
                             server: url.absoluteString, device: device.info.name)
    }

    /// Makes `connection` this TV's server for a sign-in by phone: whoever the phone
    /// approves signs in, so the previous profile is left.
    private func adopt(_ connection: ServerConnection, url: URL) {
        settings.serverURL = url
        settings.serverId = connection.serverId
        settings.lastUserId = nil
        server = connection
        profileClient = nil
        profileSwitch = nil
        supportsPairing = true
        signInMethod = .phone
        phaseBeforeServerChange = nil
    }

    /// The code a phone setup started, for the sign-in screen to poll (once).
    func takePendingPairingTicket() -> PairingTicket? {
        defer { pendingPairingTicket = nil }
        return pendingPairingTicket
    }

    /// The TV's side of QR sign-in on the connected server (nil before a server is).
    func makePairingSession() -> PairingSession? {
        guard let server else { return nil }
        return PairingSession(api: server.client, device: device.info, describe: { AppState.userMessage(for: $0) })
    }

    /// The server turned out to have no QR sign-in: the picker is the only way in.
    func pairingUnsupported() {
        supportsPairing = false
        signInMethod = .remote
    }

    /// Reads the signed-in profile again (`/api/me`): its photo, name or kid flag may have
    /// changed on the web while the TV stayed on. Errors leave the profile as it is (a 401
    /// reaches `handleUnauthorized` through the client).
    func refreshUser() async {
        guard let client = profileClient, let current = currentUser,
              let user = try? await client.me(), user.id == current.id, user != current,
              client === profileClient
        else { return }
        phase = .signedIn(user)
    }

    /// The profile's separate histories (`GET /api/me/managed`), for the picker.
    func managedAccounts() async throws -> [ManagedAccount] {
        guard let client = profileClient else { return [] }
        return try await client.managedAccounts()
    }

    /// «Отдельная история на этом устройстве»: switches this Apple TV's history and puts
    /// the answer into the signed-in user. The shell is keyed by it (`RootView`), so Home,
    /// Continue Watching and every page load again for the new history, and the Top Shelf
    /// follows.
    func setDeviceHistory(_ change: DeviceHistoryChange) async throws {
        guard let client = profileClient, var user = currentUser else { return }
        let history = try await client.setDeviceHistory(change)
        // The profile may have changed meanwhile: then this answer is not the current user's.
        guard client === profileClient, currentUser?.id == user.id else { return }
        user.deviceHistory = history
        phase = .signedIn(user)
        TVTopShelfContentProvider.topShelfContentDidChange()
    }

    /// A new separate history named `name`, then this Apple TV writes into it.
    func createDeviceHistory(named name: String) async throws {
        guard let client = profileClient else { return }
        let account = try await client.createManagedAccount(name: name)
        try await setDeviceHistory(.on(accountId: account.id))
    }

    /// Reads the profile's interface language and switches the app to it.
    func refreshInterfaceLanguage() async {
        guard let client = profileClient, let value = try? await client.uiLanguage() else { return }
        applyInterfaceLanguage(value)
    }

    /// «Язык интерфейса»: "" (as the profile), "ru" or "en", saved for the profile.
    func setInterfaceLanguage(_ language: String) async throws {
        guard let client = profileClient else { return }
        applyInterfaceLanguage(try await client.setUILanguage(language))
    }

    /// Reads the profile's channel-list choices (Settings shows them).
    func refreshChannelPrefs() async {
        guard let client = profileClient else { return }
        let prefs = try? await client.channelPrefs()
        guard client === profileClient else { return }
        channelPrefs = prefs
    }

    /// «Избранные каналы первыми»: saved for the profile; the TV page reloads its list.
    func setFavoritesFirst(_ on: Bool) async throws {
        guard let client = profileClient else { return }
        let saved = try await client.setChannelPrefs(ChannelPrefs(favoritesFirst: on))
        guard client === profileClient else { return }
        channelPrefs = saved
        channelPrefsRevision += 1
        TVTopShelfContentProvider.topShelfContentDidChange()
    }

    private func applyInterfaceLanguage(_ value: UILanguage) {
        interfaceLanguage = value
        language = AppLanguage(rawValue: value.effective) ?? .system
    }

    /// Opens the profile picker over the live session: nothing is revoked or forgotten (its
    /// client, token and `lastUserId` stay), so `cancelSwitch` returns to it and a restart is
    /// still signed in.
    func switchProfile() {
        guard server != nil, let user = currentUser, profileClient != nil else { return }
        profileSwitch = ProfileSwitch(from: user)
        signInMethod = .remote
        phase = .needsProfile
    }

    /// Menu on the picker «Switch Profile» opened: back to that session, where the user was.
    func cancelSwitch() {
        guard let change = profileSwitch, profileClient != nil else { return }
        profileSwitch = nil
        phase = .signedIn(change.from)
    }

    /// Revokes the current token on the server and forgets it.
    func signOut() async {
        guard let server, let user = currentUser, let profileClient else { return }
        try? await profileClient.signOut()
        try? tokens.removeToken(for: CredentialKey(serverId: server.serverId, userId: user.id))
        leaveProfile()
    }

    /// Called when any request reports `401`. That alone ends nothing: `/api/me` is asked with
    /// the same token, and only its `401` signs the profile out (the token was revoked).
    func handleUnauthorized() {
        guard sessionCheck == nil, let client = profileClient, shellUser != nil else { return }
        sessionCheck = Task { [weak self] in
            let expired = await client.sessionExpired()
            guard let self else { return }
            self.sessionCheck = nil
            // Another profile signed in meanwhile: its session is not the one checked.
            guard expired, client === self.profileClient, let server = self.server, let user = self.shellUser else { return }
            try? self.tokens.removeToken(for: CredentialKey(serverId: server.serverId, userId: user.id))
            self.leaveProfile()
        }
    }

    private func leaveProfile() {
        profileSwitch = nil
        profileClient = nil
        settings.lastUserId = nil
        phase = .needsProfile
    }

    /// Shows `message` in the shell's banner for a few seconds.
    func showNotice(_ message: String) {
        timedNotice.show(message)
    }

    /// Records a change to the profile's library state (for example the watchlist).
    func libraryChanged() {
        libraryRevision += 1
    }

    /// Routes a failed request to a message to show. A `401` also asks `/api/me`
    /// (`handleUnauthorized`), which signs the profile out to the picker only when it is `401` too.
    func message(for error: Error) -> String? {
        if let error = error as? APIError, error.statusCode == 401 {
            handleUnauthorized()
        }
        return Self.userMessage(for: error)
    }

    /// A localized, non-technical description of a failure: the server's own message
    /// when it sent one (in the app language), otherwise a plain explanation.
    nonisolated static func userMessage(for error: Error) -> String {
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
        profileSwitch = nil
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

/// The address is plain http to a host away from the home network: the profile's password
/// would cross the internet in the clear. `AppState.connect(to:allowUnencrypted:)` throws it
/// until the viewer agrees.
struct UnencryptedConnection: Error {}

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
