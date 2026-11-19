import Foundation

/// A filter of the one channel list: all channels, the profile's favourites, or one category
/// by its id (`ChannelCategory.id`: `ai:news`, `source:3`, `group:<name>`). Filters never
/// reorder: every view keeps the server's order (by number, the favourites first when the
/// profile wants them so).
///
/// An exclusive category (the server's `exclusive: true`, the adult one) is exclusive, as on
/// a TV: its channels (`Channel.exclusiveCategory`) are shown in it and nowhere else (not in
/// All, Favourites, other categories, channel up / down or a number typed outside it), and
/// it is the list's last entry.
public enum ChannelFilter: Hashable, Sendable {
    case all
    case favorites
    case category(String)

    /// The id of a playlist group or an own channel's category `name` ("" : no category).
    public static func groupID(_ name: String) -> String { "group:" + name }

    /// The category id that means «no category»: the channels that are in none.
    public static let noCategory = groupID("")

    /// A channel's category ids: the server's `Channel.categories`, and for a server that
    /// sends none (older, or the channel is in none) its own `category` as a group, as the
    /// web app does.
    public static func categories(of channel: Channel) -> [String] {
        if let ids = channel.categories { return ids }
        let own = channel.category.trimmingCharacters(in: .whitespaces)
        return own.isEmpty ? [] : [groupID(own)]
    }

    /// The category list of a channel list, with the channels each really has: the
    /// server's list (`server`: the names in the viewer's language, the kinds and the
    /// order: AI topics, sources, groups) when it sent one, else the channels' own
    /// categories in the order of their lowest channel number (older servers; a trailing
    /// «no category» entry when some channels have none and others are grouped). A
    /// category nobody is in is left out.
    public static func categoryList(for channels: [Channel], server: [ChannelCategory]?) -> [ChannelCategory] {
        var counts: [String: Int] = [:]
        var firstSeen: [String] = []
        var ungrouped = 0
        for channel in channels.sorted(by: Channel.byNumber) {
            // a channel of an exclusive category counts in it only
            let ids = channel.exclusiveCategory.map { [$0] } ?? categories(of: channel)
            if ids.isEmpty { ungrouped += 1 }
            for id in ids {
                if counts[id] == nil { firstSeen.append(id) }
                counts[id, default: 0] += 1
            }
        }
        if let server {
            let listed = server.compactMap { category in
                counts[category.id].map { ChannelCategory(id: category.id, name: category.name, kind: category.kind, count: $0, exclusive: category.exclusive) }
            }
            return exclusiveLast(listed)
        }
        // Without the server's list only a group can be named (its own text); a topic or
        // source id has no name here.
        let groups = firstSeen.filter { $0.hasPrefix("group:") }.map {
            ChannelCategory(id: $0, name: String($0.dropFirst("group:".count)), kind: ChannelCategory.kindGroup, count: counts[$0] ?? 0)
        }
        guard ungrouped > 0, !groups.isEmpty else { return groups }
        return groups + [ChannelCategory(id: noCategory, name: "", kind: ChannelCategory.kindGroup, count: ungrouped)]
    }

    /// The list with its exclusive categories moved to its end.
    static func exclusiveLast(_ list: [ChannelCategory]) -> [ChannelCategory] {
        list.filter { !$0.exclusive } + list.filter(\.exclusive)
    }

    /// What the list offers, as the web's first level: Favourites and All, then
    /// `categoryList`, each with its count.
    public static func options(for channels: [Channel], server: [ChannelCategory]? = nil) -> [ChannelFilterOption] {
        [
            ChannelFilterOption(filter: .favorites, count: channels.filter(ChannelFilter.favorites.matches).count),
            ChannelFilterOption(filter: .all, count: channels.filter(ChannelFilter.all.matches).count),
        ] + categoryList(for: channels, server: server).map {
            ChannelFilterOption(filter: .category($0.id), count: $0.count, label: $0.name, kind: $0.kind, exclusive: $0.exclusive)
        }
    }

    /// What a category filter is called: its name in `categories` (the server's list),
    /// else a group's own name; nil when it has none to show (no category, or an id
    /// nobody named). nil for All and Favourites too: the app names those itself.
    public func categoryName(in categories: [ChannelCategory]) -> String? {
        guard case .category(let id) = self else { return nil }
        if let name = categories.first(where: { $0.id == id })?.name, !name.isEmpty { return name }
        guard id.hasPrefix("group:") else { return nil }
        let own = String(id.dropFirst("group:".count))
        return own.isEmpty ? nil : own
    }

    /// The channel a typed number tunes to: the channel of that number in the list, but one
    /// of an exclusive category only while this filter is that category (as everywhere
    /// else, it is not reachable from outside it). nil when there is none.
    public func channel(number: Int, in channels: [Channel]) -> Channel? {
        channels.first { channel in
            guard channel.number == number else { return false }
            guard let only = channel.exclusiveCategory else { return true }
            return self == .category(only)
        }
    }

    /// The channels this filter shows, in the list's order.
    public func apply(to channels: [Channel]) -> [Channel] {
        channels.filter(matches)
    }

    public func matches(_ channel: Channel) -> Bool {
        // an exclusive category's channels are in it only
        if let only = channel.exclusiveCategory { return self == .category(only) }
        switch self {
        case .all: return true
        case .favorites: return channel.favorite
        case .category(let id):
            let ids = Self.categories(of: channel)
            return id == Self.noCategory ? ids.isEmpty : ids.contains(id)
        }
    }

    /// This filter while it still means something in `channels`: a category nobody is in
    /// any more falls back to All.
    public func valid(in channels: [Channel]) -> ChannelFilter {
        guard case .category = self else { return self }
        return channels.contains(where: matches) ? self : .all
    }

    /// What channel up / down goes through: this filter's channels in the list's order, with
    /// `current` kept in its place in the list even when it no longer matches (a favourite
    /// just removed), so zapping on from it never jumps. A `current` the list lacks goes last.
    public func zapList(_ channels: [Channel], current: Channel) -> [Channel] {
        var list = channels.filter { matches($0) || $0.id == current.id }
        if !list.contains(where: { $0.id == current.id }) { list.append(current) }
        return list
    }

    /// The filter as it is stored ("all", "favorites", "cat:<id>").
    public var storageKey: String {
        switch self {
        case .all: return "all"
        case .favorites: return "favorites"
        case .category(let id): return "cat:" + id
        }
    }

    public init(storageKey: String) {
        switch storageKey {
        case "favorites": self = .favorites
        case let key where key.hasPrefix("cat:"): self = .category(String(key.dropFirst("cat:".count)))
        // What a filter was stored as while a category was only the channel's `category`
        // text: that text is now the group of that name.
        case let key where key.hasPrefix("category:"): self = .category(Self.groupID(String(key.dropFirst("category:".count))))
        default: self = .all
        }
    }
}

/// One category of the viewer's list (`categories` of `GET /api/channels`): `id` is
/// `ai:<code>` (a topic the server's AI helper made), `source:<id>` (an external source,
/// when there are two or more) or `group:<name>` (a playlist's group-title, an own
/// channel's category); `name` is in the viewer's language. The server sends them in the
/// filter's order: topics, sources, groups. `count` is the server's count of channels; the
/// app counts what it shows itself (`ChannelFilter.categoryList`).
public struct ChannelCategory: Decodable, Hashable, Sendable {
    public static let kindAI = "ai"
    public static let kindSource = "source"
    public static let kindGroup = "group"

    public var id: String
    public var name: String
    public var kind: String
    public var count: Int
    /// Its channels are shown in it and nowhere else, and it comes last (the adult
    /// category, `ai:adult`). false from a server that does not say.
    public var exclusive: Bool

    public init(id: String, name: String, kind: String = ChannelCategory.kindGroup, count: Int = 0, exclusive: Bool = false) {
        self.id = id
        self.name = name
        self.kind = kind
        self.count = count
        self.exclusive = exclusive
    }

    enum CodingKeys: String, CodingKey { case id, name, kind, count, exclusive }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = c.value(.name, default: "")
        kind = c.value(.kind, default: ChannelCategory.kindGroup)
        count = c.value(.count, default: 0)
        exclusive = c.value(.exclusive, default: false)
    }

    /// Sets each channel's `exclusiveCategory`: the first of its categories that `categories`
    /// marks exclusive (nil: none).
    public static func markExclusive(_ channels: inout [Channel], in categories: [ChannelCategory]?) {
        let exclusive = Set((categories ?? []).filter(\.exclusive).map(\.id))
        for index in channels.indices {
            channels[index].exclusiveCategory = exclusive.isEmpty ? nil : ChannelFilter.categories(of: channels[index]).first(where: exclusive.contains)
        }
    }
}

/// One entry of the category list: a filter, how many channels it lets through, and for a
/// category its `label` (the viewer's language; "": channels without a category) and
/// `kind` (`ChannelCategory.kindAI` and so on).
public struct ChannelFilterOption: Hashable, Sendable, Identifiable {
    public var filter: ChannelFilter
    public var count: Int
    public var label: String?
    public var kind: String?
    /// An exclusive category (`ChannelCategory.exclusive`): last, without a heading.
    public var exclusive: Bool

    public var id: ChannelFilter { filter }

    public init(filter: ChannelFilter, count: Int, label: String? = nil, kind: String? = nil, exclusive: Bool = false) {
        self.filter = filter
        self.count = count
        self.label = label
        self.kind = kind
        self.exclusive = exclusive
    }
}
