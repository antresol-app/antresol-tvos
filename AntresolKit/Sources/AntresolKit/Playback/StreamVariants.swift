import Foundation

/// The picture sizes an external channel's master playlist offers (`EXT-X-STREAM-INF`
/// `RESOLUTION`), for its «Качество» menu: «Авто» and one row per height, tallest first.
/// The player caps `AVPlayerItem.preferredMaximumResolution` at the picked size.
public struct StreamVariants: Equatable, Sendable {
    public struct Size: Equatable, Sendable, Hashable {
        public let width: Int
        public let height: Int

        public init(width: Int, height: Int) {
            self.width = width
            self.height = height
        }

        /// "720p".
        public var label: String { "\(height)p" }
    }

    /// One per height (the widest of each), tallest first.
    public let sizes: [Size]

    public init(sizes: [Size] = []) {
        var widest: [Int: Size] = [:]
        for size in sizes where size.width > 0 && size.height > 0 {
            if size.width > widest[size.height]?.width ?? 0 { widest[size.height] = size }
        }
        self.sizes = widest.values.sorted { $0.height > $1.height }
    }

    /// Parses a master playlist; a media playlist or one without `RESOLUTION` gives none.
    public init(master: String) {
        var sizes: [Size] = []
        for raw in master.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("#EXT-X-STREAM-INF:") else { continue }
            let attrs = LiveRenditions.attributes(String(line.dropFirst("#EXT-X-STREAM-INF:".count)))
            let parts = (attrs["RESOLUTION"] ?? "").lowercased().split(separator: "x")
            guard parts.count == 2, let w = Int(parts[0]), let h = Int(parts[1]) else { continue }
            sizes.append(Size(width: w, height: h))
        }
        self.init(sizes: sizes)
    }

    public init(master data: Data) {
        self.init(master: String(decoding: data, as: UTF8.self))
    }

    /// The menu is offered only when there is a choice.
    public var offersChoice: Bool { sizes.count > 1 }

    /// The size a remembered cap height picks: that height when the stream has it, else
    /// the tallest under it; nil («Авто») when there is none.
    public func size(forCap height: Int?) -> Size? {
        guard let height else { return nil }
        return sizes.first { $0.height <= height }
    }
}
