import Foundation

// Authentication, profiles and device sessions (§2).
extension APIClient {
    /// `GET /api/health` (no auth). Use it to validate a server address.
    public func health() async throws -> ServerHealth {
        try await send(.get, "/api/health")
    }

    /// `GET /api/setup` (no auth).
    public func setupStatus() async throws -> SetupStatus {
        try await send(.get, "/api/setup")
    }

    /// `GET /api/profiles` (no auth): the profile picker.
    public func profiles() async throws -> [Profile] {
        try await send(.get, "/api/profiles")
    }

    /// `POST /api/auth/token`: signs in and stores the returned token on this client.
    /// Re-registering the same device id revokes that device's previous token.
    @discardableResult
    public func signIn(userId: Int, password: String?, device: DeviceInfo) async throws -> TokenResponse {
        let password = password.flatMap { $0.isEmpty ? nil : $0 }
        let response: TokenResponse = try await send(
            .post, "/api/auth/token", json: TokenRequest(userId: userId, password: password, device: device)
        )
        token = response.token
        return response
    }

    /// `GET /api/me`. A `401` means the stored token is no longer valid.
    public func me() async throws -> User {
        try await send(.get, "/api/me")
    }

    /// `GET /api/me/playback-prefs`: the profile's audio and subtitle defaults.
    public func playbackPrefs() async throws -> PlaybackPrefs {
        try await send(.get, "/api/me/playback-prefs")
    }

    /// `PUT /api/me/playback-prefs/auto-skip`: turns «Пропускать сам» on or off for one kind
    /// ("recap", "intro" or "credits"); the others stay. Answers with the profile's prefs.
    public func setAutoSkip(_ kind: String, _ on: Bool) async throws -> PlaybackPrefs {
        try await send(.put, "/api/me/playback-prefs/auto-skip", json: [kind: on])
    }

    /// `POST /api/logout`: revokes the current token and forgets it.
    public func signOut() async throws {
        defer { token = nil }
        try await sendWithoutResponse(.post, "/api/logout")
    }

    /// `POST /api/auth/media-key`: a 12-hour key for `?mk=` on media URLs.
    public func mediaKey() async throws -> MediaKey {
        try await send(.post, "/api/auth/media-key")
    }

    /// `GET /api/me/devices`.
    public func devices() async throws -> [DeviceSession] {
        try await send(.get, "/api/me/devices", as: ItemsEnvelope<DeviceSession>.self).items
    }

    /// `DELETE /api/me/devices/{id}`.
    public func revokeDevice(id: Int) async throws {
        try await sendWithoutResponse(.delete, "/api/me/devices/\(id)")
    }

    /// `GET /api/library/status` (admin).
    public func libraryStatus() async throws -> LibraryStatus {
        try await send(.get, "/api/library/status")
    }
}

/// `GET/PUT /api/me/ui-language`: the profile's interface language. `language` is what
/// the profile chose ("" none: follow the profile's audio languages, then the
/// household's); `effective` is what the apps use for their whole interface ("" follow
/// the device).
public struct UILanguage: Codable, Hashable, Sendable {
    public var language: String
    public var effective: String

    public init(language: String = "", effective: String = "") {
        self.language = language
        self.effective = effective
    }

    enum CodingKeys: String, CodingKey { case language, effective }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        language = c.value(.language, default: "")
        effective = c.value(.effective, default: "")
    }
}

private struct UILanguageBody: Encodable {
    let language: String
}

extension APIClient {
    public func uiLanguage() async throws -> UILanguage {
        try await send(.get, "/api/me/ui-language")
    }

    /// Chooses the profile's interface language ("ru", "en", or "" for "as the profile").
    public func setUILanguage(_ language: String) async throws -> UILanguage {
        try await send(.put, "/api/me/ui-language", json: UILanguageBody(language: language))
    }
}
