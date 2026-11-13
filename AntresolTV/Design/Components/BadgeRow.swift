import SwiftUI

/// Server-provided badges ("1080p", "Audio EN RU") as small outlined chips.
/// Audio and subtitle languages show an icon in place of the word
/// ("Audio RU EN" → 🔈 RU EN), as in the web and iPhone apps; VoiceOver
/// still reads the word.
struct BadgeRow: View {
    let badges: [String]

    var body: some View {
        HStack(spacing: 8) {
            ForEach(badges, id: \.self) { badge in
                let label = BadgeLabel(badge)
                HStack(spacing: 6) {
                    if let symbol = label.symbol {
                        Image(systemName: symbol).imageScale(.small)
                    }
                    if !label.rest.isEmpty { Text(verbatim: label.rest) }
                }
                    .font(Theme.Typography.badge)
                    .foregroundStyle(Theme.Colors.label2)
                    .lineLimit(1)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.Radius.badge, style: .continuous)
                            .fill(Theme.Colors.fillSecondary)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.Radius.badge, style: .continuous)
                            .strokeBorder(Theme.Colors.hairline, lineWidth: 1)
                    )
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text(verbatim: badge))
            }
        }
    }
}

/// A badge's text split into an icon for the audio or subtitles word (the
/// server's, in either language) and the rest.
struct BadgeLabel: Equatable {
    var symbol: String?
    var rest: String

    init(symbol: String?, rest: String) {
        self.symbol = symbol
        self.rest = rest
    }

    init(_ text: String) {
        for (words, symbol) in [(["Звук", "Аудио", "Audio"], "speaker.wave.2"), (["Субтитры", "Subtitles"], "captions.bubble")] {
            for word in words where text == word || text.hasPrefix(word + " ") || text.hasPrefix(word + ":") {
                var rest = text.dropFirst(word.count)
                if rest.hasPrefix(":") { rest = rest.dropFirst() }
                self.init(symbol: symbol, rest: rest.trimmingCharacters(in: .whitespaces))
                return
            }
        }
        self.init(symbol: nil, rest: text)
    }
}

/// A thin watched-fraction bar.
struct ProgressBar: View {
    /// 0...1.
    let value: Double
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.28))
                Capsule()
                    .fill(.white)
                    .frame(width: proxy.size.width * min(max(value, 0), 1))
            }
        }
        .frame(height: height)
        .accessibilityElement()
        .accessibilityValue(Text(verbatim: "\(Int((min(max(value, 0), 1) * 100).rounded()))%"))
    }
}
