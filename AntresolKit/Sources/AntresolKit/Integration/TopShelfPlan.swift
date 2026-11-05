import Foundation

/// What the Apple TV Top Shelf shows, derived from `/api/home`: the profile's Continue
/// Watching row and the newest movies and shows, interleaved.
public struct TopShelfPlan: Sendable, Equatable {
    public enum SectionKind: String, Sendable {
        case continueWatching
        case recentlyAdded
    }

    /// The artwork shape a section uses.
    public enum Shape: Sendable {
        /// 16:9, backdrop first.
        case wide
        /// 2:3 poster.
        case poster
    }

    public struct Entry: Sendable, Equatable {
        public let card: Card
        /// Server-relative image path for the section's shape, or nil when the card has none.
        public let imagePath: String?
        /// Watched fraction to draw on the tile, nil when nothing was watched yet.
        public let progress: Double?
        /// Opens the item's page.
        public let displayURL: URL
        /// Starts playback, for playable kinds.
        public let playURL: URL?
    }

    public struct Section: Sendable, Equatable {
        public let kind: SectionKind
        /// The server's localized shelf title, when the section maps to exactly one shelf.
        public let serverTitle: String?
        public let shape: Shape
        public let entries: [Entry]
    }

    public let sections: [Section]

    /// Server shelf ids feeding each section.
    public static let continueShelf = "continue"
    public static let recentShelves = ["recent-movies", "recent-series"]

    public init(home: HomeResponse, maxItemsPerSection: Int = 12) {
        var sections: [Section] = []

        if let shelf = home.shelf(Self.continueShelf) {
            let cards = Self.unique(shelf.cards.filter { $0.kind.isVideo }).prefix(maxItemsPerSection)
            if !cards.isEmpty {
                sections.append(Section(
                    kind: .continueWatching,
                    serverTitle: shelf.title.isEmpty ? nil : shelf.title,
                    shape: .wide,
                    entries: cards.map { Self.entry($0, shape: .wide) }
                ))
            }
        }

        let recentRows = Self.recentShelves.compactMap { home.shelf($0)?.cards }
        let recent = Self.unique(Self.interleave(recentRows)).prefix(maxItemsPerSection)
        if !recent.isEmpty {
            sections.append(Section(
                kind: .recentlyAdded,
                serverTitle: nil,
                shape: .poster,
                entries: recent.map { Self.entry($0, shape: .poster) }
            ))
        }
        self.sections = sections
    }

    static func entry(_ card: Card, shape: Shape) -> Entry {
        let candidates: [String]
        switch shape {
        case .wide: candidates = [card.backdrop, card.poster]
        case .poster: candidates = [card.poster, card.backdrop]
        }
        let progress = card.progress > 0 ? min(card.progress, 1) : nil
        return Entry(
            card: card,
            imagePath: candidates.first { !$0.isEmpty },
            progress: progress,
            displayURL: DeepLink.item(id: card.id).url,
            playURL: card.kind.isVideo ? DeepLink.play(id: card.id).url : nil
        )
    }

    /// Round-robin merge: first of each row, then the second of each, and so on.
    static func interleave(_ rows: [[Card]]) -> [Card] {
        var result: [Card] = []
        let longest = rows.map(\.count).max() ?? 0
        for index in 0..<longest {
            for row in rows where index < row.count {
                result.append(row[index])
            }
        }
        return result
    }

    static func unique(_ cards: [Card]) -> [Card] {
        var seen = Set<String>()
        return cards.filter { seen.insert($0.uniqueKey).inserted }
    }
}
