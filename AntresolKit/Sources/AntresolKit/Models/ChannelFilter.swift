import Foundation

/// A filter of the one channel list: all channels, the profile's favourites, or one category
/// by its id (`ChannelCategory.id`: `ai:news`, `source:3`, `group:<name>`). Filters never
/// reorder: a TV list keeps its numbers.
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
            let ids = categories(of: channel)
            if ids.isEmpty { ungrouped += 1 }
            for id in ids {
                if counts[id] == nil { firstSeen.append(id) }
                counts[id, default: 0] += 1
            }
        }
        if let server {
            return server.compactMap { category in
                counts[category.id].map { ChannelCategory(id: category.id, name: category.name, kind: category.kind, count: $0) }
            }
        }
        // Without the server's list only a group can be named (its own text); a topic or
        // source id has no name here.
        let groups = firstSeen.filter { $0.hasPrefix("group:") }.map {
            ChannelCategory(id: $0, name: String($0.dropFirst("group:".count)), kind: ChannelCategory.kindGroup, count: counts[$0] ?? 0)
        }
        guard ungrouped > 0, !groups.isEmpty else { return groups }
        return groups + [ChannelCategory(id: noCategory, name: "", kind: ChannelCategory.kindGroup, count: ungrouped)]
    }

    /// What the list offers: All and Favourites, then `categoryList`, each with its count.
    public static func options(for channels: [Channel], server: [ChannelCategory]? = nil) -> [ChannelFilterOption] {
        [
            ChannelFilterOption(filter: .all, count: channels.count),
            ChannelFilterOption(filter: .favorites, count: channels.filter(\.favorite).count),
        ] + categoryList(for: channels, server: server).map {
            ChannelFilterOption(filter: .category($0.id), count: $0.count, label: $0.name, kind: $0.kind)
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

    /// The channels this filter shows, by number.
    public func apply(to channels: [Channel]) -> [Channel] {
        channels.filter(matches).sorted(by: Channel.byNumber)
    }

    public func matches(_ channel: Channel) -> Bool {
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

    public init(id: String, name: String, kind: String = ChannelCategory.kindGroup, count: Int = 0) {
        self.id = id
        self.name = name
        self.kind = kind
        self.count = count
    }

    enum CodingKeys: String, CodingKey { case id, name, kind, count }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = c.value(.name, default: "")
        kind = c.value(.kind, default: ChannelCategory.kindGroup)
        count = c.value(.count, default: 0)
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

    public var id: ChannelFilter { filter }

    public init(filter: ChannelFilter, count: Int, label: String? = nil, kind: String? = nil) {
        self.filter = filter
        self.count = count
        self.label = label
        self.kind = kind
    }
}
