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
