import Foundation

/// «Switch Profile» opened over a live session: the profile it was opened from stays signed
/// in (its token, its client, its shell) until another profile signs in.
public struct ProfileSwitch: Hashable, Sendable {
    /// The signed-in profile the picker was opened over.
    public let from: User

    public init(from: User) {
        self.from = from
    }

    /// Picking `profileId` on the picker: the profile being switched from goes straight back
    /// to its session, with no password asked.
    public func returnsToCurrent(picking profileId: Int) -> Bool {
        profileId == from.id
    }

    /// After `userId` signed in: whether the left profile's token is revoked now. A password
    /// profile's is (a stored token never lets anyone back in without the password); a
    /// passwordless one stays stored for a quick switch back.
    public func revokesLeftToken(signedInAs userId: Int) -> Bool {
        userId != from.id && from.hasPassword
    }
}

extension APIClient {
    /// A `401` from any endpoint only means «ask `/api/me`»: true only when `/api/me` answers
    /// `401` too. Any other answer, or no answer, keeps the session.
    public func sessionExpired() async -> Bool {
        do {
            _ = try await me()
            return false
        } catch let error as APIError {
            return error.statusCode == 401
        } catch {
            return false
        }
    }
}
