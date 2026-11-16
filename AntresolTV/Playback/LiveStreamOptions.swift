import AVFoundation

/// A rendition of the stream on screen.
struct StreamOption: Equatable {
    /// The HLS `NAME` when the asset keeps it (the option's title metadata), else
    /// AVFoundation's display name (made from the language: «Английский» for "English").
    let name: String
    /// The extended language tag ("ru", "en", "mul").
    let language: String
    let isForcedOnly: Bool
    /// CEA-608/708 captions carried in the video, not a subtitle rendition.
    let isClosedCaptions: Bool

    /// The name an external stream's menu shows: captions marked «(CC)».
    var menuName: String { isClosedCaptions ? "\(name) (CC)" : name }

    init(_ option: AVMediaSelectionOption, title: String? = nil) {
        isClosedCaptions = option.mediaType == .closedCaption
        name = title ?? option.displayName
        language = option.extendedLanguageTag ?? option.locale?.language.languageCode?.identifier ?? ""
        isForcedOnly = option.hasMediaCharacteristic(.containsOnlyForcedSubtitles)
    }

    /// The options with their titles loaded.
    static func describe(_ options: [AVMediaSelectionOption]) async -> [StreamOption] {
        var out: [StreamOption] = []
        for option in options {
            let titles = AVMetadataItem.metadataItems(from: option.commonMetadata, filteredByIdentifier: .commonIdentifierTitle)
            let title = try? await titles.first?.load(.stringValue)
            out.append(StreamOption(option, title: title ?? nil))
        }
        return out
    }
}

/// Hands the subtitle text of a live item to the model (the player draws none itself).
final class LiveLegibleReceiver: NSObject, AVPlayerItemLegibleOutputPushDelegate {
    let output = AVPlayerItemLegibleOutput()
    private let onText: @MainActor (String?) -> Void

    init(onText: @escaping @MainActor (String?) -> Void) {
        self.onText = onText
        super.init()
        output.suppressesPlayerRendering = true
        output.setDelegate(self, queue: .main)
    }

    func legibleOutput(
        _ output: AVPlayerItemLegibleOutput, didOutputAttributedStrings strings: [NSAttributedString],
        nativeSampleBuffers nativeSamples: [Any], forItemTime itemTime: CMTime
    ) {
        let text = strings.map(\.string).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        MainActor.assumeIsolated { onText(text.isEmpty ? nil : text) }
    }
}
