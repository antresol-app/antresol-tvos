import Foundation

/// The channel a profile watched last, kept on the device for the TV tab's "Continue"
/// card: one channel id per server and profile.
public struct LastChannelStore {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    static func key(for profile: CredentialKey) -> String {
        "tv.lastChannel.\(profile.account)"
    }

    public func channelId(for profile: CredentialKey) -> Int? {
        defaults.object(forKey: Self.key(for: profile)) as? Int
    }

    public func remember(_ channelId: Int, for profile: CredentialKey) {
        defaults.set(channelId, forKey: Self.key(for: profile))
    }

    public func forget(for profile: CredentialKey) {
        defaults.removeObject(forKey: Self.key(for: profile))
    }

    /// The last channel as the current list has it (with what is on now), or nil when there
    /// is none or the profile no longer sees it.
    public static func channel(_ id: Int?, in channels: [Channel]) -> Channel? {
        guard let id else { return nil }
        return channels.first { $0.id == id }
    }
}
