import Foundation

/// Building `PATCH /api/music/playlists/{id}` edits and applying them to the tracks on
/// screen, so a page can show the result before the server answers.
public enum PlaylistEditing {
    /// The trimmed name, or nil when nothing is left (the server answers `400` then).
    public static func normalizedName(_ raw: String) -> String? {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    /// The `order` permutation that moves the entry at `source` to `destination` in a
    /// playlist of `count` entries; nil when either position is out of range or nothing moves.
    public static func moveOrder(from source: Int, to destination: Int, count: Int) -> [Int]? {
        guard source != destination, (0..<count).contains(source), (0..<count).contains(destination) else { return nil }
        var order = Array(0..<count)
        order.remove(at: source)
        order.insert(source, at: destination)
        return order
    }

    /// `elements` rearranged by `order` (`order[i]` is the old position placed at `i`);
    /// unchanged when `order` is not a permutation of its positions.
    public static func apply<Element>(order: [Int], to elements: [Element]) -> [Element] {
        guard order.count == elements.count, Set(order) == Set(elements.indices) else { return elements }
        return order.map { elements[$0] }
    }

    /// `elements` without the given positions.
    public static func removing<Element>(positions: [Int], from elements: [Element]) -> [Element] {
        let removed = Set(positions)
        return elements.enumerated().filter { !removed.contains($0.offset) }.map(\.element)
    }
}

extension PlaylistUpdate {
    /// Renames the playlist.
    public static func rename(to name: String) -> PlaylistUpdate {
        PlaylistUpdate(name: name)
    }

    /// Appends tracks (by track id) at the end.
    public static func append(_ trackIds: [Int]) -> PlaylistUpdate {
        PlaylistUpdate(append: trackIds)
    }

    /// Removes the entries at these positions.
    public static func remove(positions: [Int]) -> PlaylistUpdate {
        PlaylistUpdate(remove: positions)
    }

    /// Moves one entry; nil when nothing would move.
    public static func move(from source: Int, to destination: Int, count: Int) -> PlaylistUpdate? {
        PlaylistEditing.moveOrder(from: source, to: destination, count: count).map { PlaylistUpdate(order: $0) }
    }
}
