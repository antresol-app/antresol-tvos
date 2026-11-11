import Foundation

/// The Top Shelf's "On Air Now" section: channels with a programme on air, in the TV tab's
/// order (sections by their lowest number, channels by number), each opening the channel.
public struct TopShelfChannels: Sendable, Equatable {
    public struct Entry: Sendable, Equatable {
        public let channel: Channel
        public let program: ChannelProgram
        /// "10 · Comedies — Night Laughs".
        public let title: String
        /// Server image path: the programme's backdrop, else its poster, else the channel's
        /// logo picture.
        public let imagePath: String
        /// How far the programme is, for the tile's progress bar.
        public let progress: Double
        /// `antresol://channel/{id}`: the app opens the live player.
        public let url: URL
    }

    public static let defaultLimit = 10

    public let entries: [Entry]

    public init(channels: [Channel], at date: Date, limit: Int = Self.defaultLimit) {
        var entries: [Entry] = []
        for channel in ChannelSection.group(channels).flatMap(\.channels) where entries.count < limit {
            guard channel.enabled, let program = channel.program(at: date), program.isOnAir(at: date) else { continue }
            let image = [program.backdrop, program.poster].first { !$0.isEmpty } ?? Self.logoPath(channel.id)
            entries.append(Entry(
                channel: channel,
                program: program,
                title: "\(channel.number) · \(channel.name) — \(program.title)",
                imagePath: image,
                progress: program.progress(at: date),
                url: DeepLink.channel(id: channel.id).url
            ))
        }
        self.entries = entries
    }

    /// `GET /api/channels/{id}/logo.png`: the channel's logo tile as a 480×270 picture.
    public static func logoPath(_ channelId: Int) -> String {
        "/api/channels/\(channelId)/logo.png"
    }
}
