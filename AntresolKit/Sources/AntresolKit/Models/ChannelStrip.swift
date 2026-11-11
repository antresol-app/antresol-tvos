import Foundation

/// The mini-guide of the live player: the channels of the current channel's section, in
/// the TV tab's order, starting at the current one. A channel the list does not have (yet)
/// gets a strip of its own.
public struct ChannelStrip: Hashable, Sendable {
    /// The section's name ("" for a strip of the current channel alone).
    public let category: String
    public let channels: [Channel]
    /// Where focus starts: the current channel.
    public let startIndex: Int

    public init(current: Channel, in channels: [Channel]) {
        if let section = ChannelSection.group(channels).first(where: { $0.channels.contains { $0.id == current.id } }) {
            category = section.category
            self.channels = section.channels
            startIndex = section.channels.firstIndex { $0.id == current.id } ?? 0
        } else {
            category = current.category
            self.channels = [current]
            startIndex = 0
        }
    }

    /// The current channel as the strip lists it.
    public var current: Channel {
        channels[startIndex]
    }
}
