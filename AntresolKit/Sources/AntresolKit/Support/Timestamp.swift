import Foundation

/// Parses and formats the RFC 3339 timestamps used by the server.
///
/// The server emits anything from whole seconds (`2026-11-05T07:58:37Z`) to
/// nanosecond precision (`2026-11-04T20:05:27.617429922Z`), which
/// `ISO8601DateFormatter` cannot read directly, so the fraction is parsed by hand.
public enum Timestamp {
    public static func parse(_ string: String?) -> Date? {
        guard var text = string?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        var fraction: Double = 0
        if let dot = text.firstIndex(of: ".") {
            let digitsEnd = text[dot...].dropFirst().firstIndex(where: { !$0.isNumber }) ?? text.endIndex
            fraction = Double("0" + text[dot..<digitsEnd]) ?? 0
            text.removeSubrange(dot..<digitsEnd)
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        guard let date = formatter.date(from: text) else { return nil }
        return date.addingTimeInterval(fraction)
    }

    public static func format(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}
