import SwiftUI

/// Server-provided badges ("1080p", "Audio EN RU") as small outlined chips.
/// Audio and subtitle languages show an icon in place of the word
/// ("Audio RU EN" → 🔈 RU EN), as in the web and iPhone apps; VoiceOver
/// still reads the word. With no languages after it, the word stays beside
/// the icon ("Subtitles" → icon + Subtitles), so a chip is never an icon alone.
/// Every chip is `BadgeMetrics.height` tall, whatever it holds.
struct BadgeRow: View {
    let badges: [String]

    /// Set by a list row that is lit white (focused): its chips turn dark on the light plate.
    @Environment(\.badgesOnLightPlate) private var onLightPlate

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
                    .foregroundStyle(onLightPlate ? Color.black.opacity(0.66) : Theme.Colors.label2)
                    .lineLimit(1)
                    .padding(.horizontal, 9)
                    .frame(height: BadgeMetrics.height)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.Radius.badge, style: .continuous)
                            .fill(onLightPlate ? Color.black.opacity(0.07) : Theme.Colors.fillSecondary)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.Radius.badge, style: .continuous)
                            .strokeBorder(onLightPlate ? Color.black.opacity(0.24) : Theme.Colors.hairline, lineWidth: 1)
                    )
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text(verbatim: badge))
            }
        }
    }
}

extension EnvironmentValues {
    /// Whether the chips sit on a light plate (a focused list row), where light-on-dark would vanish.
    @Entry var badgesOnLightPlate = false
}

enum BadgeMetrics {
    /// One height for every chip: a symbol is taller than the text beside it, so the content's own
    /// height would make a chip with an icon larger than one without.
    static let height: CGFloat = 30
}

/// One badge in the accent colour: «New» on an episode (the web's accent badge).
struct AccentBadge: View {
    let text: String

    var body: some View {
        Text(verbatim: text)
            .font(Theme.Typography.badge)
            .foregroundStyle(Theme.Colors.accent)
            .lineLimit(1)
            .padding(.horizontal, 9)
            .frame(height: BadgeMetrics.height)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.badge, style: .continuous)
                    .fill(Theme.Colors.accent.opacity(0.16))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.badge, style: .continuous)
                    .strokeBorder(Theme.Colors.accent.opacity(0.4), lineWidth: 1)
            )
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: text))
    }
}

/// A badge's text split into an icon for the audio or subtitles word (the
/// server's, in either language) and the rest. A badge that is the word alone (no
/// languages) keeps it, in the app's language, as its rest: an icon alone says too little.
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
                let languages = rest.trimmingCharacters(in: .whitespaces)
                self.init(symbol: symbol, rest: languages.isEmpty ? Self.word(for: symbol) : languages)
                return
            }
        }
        self.init(symbol: nil, rest: text)
    }

    /// The word an icon stands for, in the app's language.
    private static func word(for symbol: String) -> String {
        symbol == "captions.bubble"
            ? String(localized: "Subtitles", bundle: .localized)
            : String(localized: "Audio", bundle: .localized)
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
