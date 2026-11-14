import Foundation

/// «Clean voice-over» in the audio menu: a cleaned voice-over is not a row
/// of its own but a switch on its studio's voice-over (as on the web and
/// the iPhone). The rows are the tracks to show, each with the track a
/// press plays (with the switch on, a voice-over's cleaned version where it
/// has one), and the switch: on or off and the track it turns to (nil: the
/// chosen voice-over has no cleaned version).
public struct CleanedSwitch: Equatable, Sendable {
    public struct Row: Equatable, Sendable {
        public var track: AudioTrack
        public var plays: Int
        public var checked: Bool
    }

    public var rows: [Row]
    public var toggle: (on: Bool, target: Int)?

    public static func == (a: CleanedSwitch, b: CleanedSwitch) -> Bool {
        a.rows == b.rows && a.toggle?.on == b.toggle?.on && a.toggle?.target == b.toggle?.target
    }

    public init(audio: [AudioTrack], audioIndex: Int?) {
        func paired(_ t: AudioTrack) -> Bool { t.isCleaned && audio.contains { $0.index == t.cleanedFrom && !$0.isCleaned } }
        func twin(of base: Int) -> AudioTrack? { audio.first { $0.isCleaned && $0.cleanedFrom == base } }
        let current = audio.first { $0.index == audioIndex }
        let on = current.map(paired) ?? false
        let base = on ? current?.cleanedFrom : audioIndex
        rows = audio.filter { !paired($0) }.map { t in
            Row(track: t, plays: on ? (twin(of: t.index)?.index ?? t.index) : t.index, checked: t.index == base)
        }
        if let base, let t = twin(of: base) {
            toggle = (on: on, target: on ? base : t.index)
        }
    }
}
