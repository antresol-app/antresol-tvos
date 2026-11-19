import Foundation

/// The Top Shelf's "On Air Now" section: channels with a programme on air, in the list's
/// order (the server's: favourites first when the profile wants them so), each opening the
/// channel. A tile's picture is the programme's still; a programme without one gets the
/// extension's neutral placeholder.
public struct TopShelfChannels: Sendable, Equatable {
    public struct Entry: Sendable, Equatable {
        public let channel: Channel
        public let program: ChannelProgram
        /// "10 · Comedies — Night Laughs".
        public let title: String
        /// Server image path: the programme's backdrop, else its poster; "" for neither.
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
        for channel in channels where entries.count < limit {
            guard channel.enabled, let program = channel.program(at: date), program.isOnAir(at: date) else { continue }
            entries.append(Entry(
                channel: channel,
                program: program,
                title: "\(channel.number) · \(channel.name) — \(program.title)",
                imagePath: program.still,
                progress: program.progress(at: date),
                url: DeepLink.channel(id: channel.id).url
            ))
        }
        self.entries = entries
    }
}
