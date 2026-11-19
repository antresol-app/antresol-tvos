import Foundation

/// A channel number being typed, as on a TV: digits from a remote or keyboard that has them,
/// or from the on-screen number pad, shown as «23_» while more may follow. The number is
/// taken `timeout` after the last digit, at once on Select, or as soon as it has as many
/// digits as the list's highest number.
public struct ChannelNumberEntry: Equatable, Sendable {
    /// How long after the last digit the number is taken.
    public static let timeout: Duration = .milliseconds(1500)

    /// The digits typed so far ("" before the first).
    public private(set) var digits = ""
    /// The most digits a number of the list has (at least one).
    public let maxDigits: Int

    /// For a list whose highest channel number is `highestNumber`.
    public init(highestNumber: Int) {
        maxDigits = max(1, String(max(0, highestNumber)).count)
    }

    public init(channels: [Channel]) {
        self.init(highestNumber: channels.map(\.number).max() ?? 0)
    }

    public var isEmpty: Bool { digits.isEmpty }

    /// Every digit a number of the list may have is typed: nothing more can follow.
    public var isComplete: Bool { digits.count >= maxDigits }

    /// Adds a digit ("0"…"9"; anything else is ignored). A leading zero is dropped. Returns
    /// whether the entry is complete now.
    @discardableResult
    public mutating func append(_ digit: Character) -> Bool {
        guard digit.isASCII, digit.isNumber, !isComplete else { return isComplete }
        if digits.isEmpty, digit == "0" { return false }
        digits.append(digit)
        return isComplete
    }

    /// Takes the last digit back (the pad's ⌫).
    public mutating func deleteLast() {
        if !digits.isEmpty { digits.removeLast() }
    }

    /// The number typed, nil before the first digit.
    public var number: Int? { Int(digits) }

    /// What the overlay shows: the digits with «_» for the next one while one may follow
    /// («2_», «23_»; complete: «234»).
    public var display: String {
        isComplete ? digits : digits + "_"
    }

    /// The first digit a key sends, nil for a key that sends none (a keyboard's or a
    /// remote's digit keys: `UIKey.characters`).
    public static func digit(in characters: String) -> Character? {
        guard characters.count == 1, let c = characters.first, c.isASCII, c.isNumber else { return nil }
        return c
    }
}
