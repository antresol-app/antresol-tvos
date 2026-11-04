import Foundation

/// One timed subtitle cue.
public struct SubtitleCue: Hashable, Sendable {
    /// Seconds on the file timeline.
    public var start: Double
    public var end: Double
    /// Plain text; markup tags are stripped, lines are joined with "\n".
    public var text: String

    public init(start: Double, end: Double, text: String) {
        self.start = start
        self.end = end
        self.text = text
    }
}

/// A minimal WebVTT parser for the subtitles served by `/api/subs` (§5.7).
public enum WebVTT {
    public static func parse(_ source: String) -> [SubtitleCue] {
        let normalized = source.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var cues: [SubtitleCue] = []
        for block in normalized.components(separatedBy: "\n\n") {
            let lines = block.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            guard let timingIndex = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            let parts = lines[timingIndex].components(separatedBy: "-->")
            guard parts.count == 2,
                  let start = timestamp(parts[0]),
                  let end = timestamp(parts[1].trimmingCharacters(in: .whitespaces).split(separator: " ").first.map(String.init) ?? "")
            else { continue }
            let text = lines[(timingIndex + 1)...].map(stripTags).joined(separator: "\n")
            guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            cues.append(SubtitleCue(start: start, end: end, text: text))
        }
        return cues.sorted { $0.start < $1.start }
    }

    /// Parses `HH:MM:SS.mmm` or `MM:SS.mmm` (a comma is accepted as the decimal separator).
    public static func timestamp(_ text: String) -> Double? {
        let fields = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".").split(separator: ":")
        guard (2...3).contains(fields.count) else { return nil }
        var seconds = 0.0
        for field in fields {
            guard let value = Double(field) else { return nil }
            seconds = seconds * 60 + value
        }
        return seconds
    }

    /// Cues shifted onto a player timeline that starts at `offset` seconds of the file
    /// (HLS sessions starting at `startSec`). Cues ending before the offset are dropped.
    public static func shift(_ cues: [SubtitleCue], by offset: Double) -> [SubtitleCue] {
        guard offset != 0 else { return cues }
        return cues.compactMap { cue in
            guard cue.end > offset else { return nil }
            return SubtitleCue(start: max(0, cue.start - offset), end: cue.end - offset, text: cue.text)
        }
    }

    /// The cue visible at `time`, if any.
    public static func cue(at time: Double, in cues: [SubtitleCue]) -> SubtitleCue? {
        cues.last { $0.start <= time && time < $0.end }
    }

    private static func stripTags(_ line: String) -> String {
        var result = ""
        var inTag = false
        for char in line {
            if char == "<" { inTag = true; continue }
            if char == ">" && inTag { inTag = false; continue }
            if !inTag { result.append(char) }
        }
        return result
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&nbsp;", with: "\u{00A0}")
    }
}
