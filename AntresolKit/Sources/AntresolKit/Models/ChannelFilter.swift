import Foundation

/// A filter of the one channel list: all channels, the profile's favourites, or one theme
/// (`Channel.category`). Filters never reorder: a TV list keeps its numbers.
public enum ChannelFilter: Hashable, Sendable {
    case all
    case favorites
    case category(String)

    /// The filters the list offers: All, Favourites, then the themes in the order of their
    /// lowest channel number. A theme of one name only once; "" is not a theme.
    public static func options(for channels: [Channel]) -> [ChannelFilter] {
        var themes: [String] = []
        for channel in channels.sorted(by: Channel.byNumber) where !channel.category.isEmpty && !themes.contains(channel.category) {
            themes.append(channel.category)
        }
        return [.all, .favorites] + themes.map(ChannelFilter.category)
    }

    /// The channels this filter shows, by number.
    public func apply(to channels: [Channel]) -> [Channel] {
        channels.filter(matches).sorted(by: Channel.byNumber)
    }

    public func matches(_ channel: Channel) -> Bool {
        switch self {
        case .all: return true
        case .favorites: return channel.favorite
        case .category(let name): return channel.category == name
        }
    }

    /// What channel up / down goes through: this filter's channels, with `current` kept in
    /// its place by number even when it no longer matches (a favourite just removed), so
    /// zapping on from it never jumps.
    public func zapList(_ channels: [Channel], current: Channel) -> [Channel] {
        var list = apply(to: channels)
        if !list.contains(where: { $0.id == current.id }) {
            list.append(channels.first { $0.id == current.id } ?? current)
            list.sort(by: Channel.byNumber)
        }
        return list
    }

    /// The filter as it is stored ("all", "favorites", "category:<name>").
    public var storageKey: String {
        switch self {
        case .all: return "all"
        case .favorites: return "favorites"
        case .category(let name): return "category:" + name
        }
    }

    public init(storageKey: String) {
        switch storageKey {
        case "favorites": self = .favorites
        case let key where key.hasPrefix("category:"): self = .category(String(key.dropFirst("category:".count)))
        default: self = .all
        }
    }
}
