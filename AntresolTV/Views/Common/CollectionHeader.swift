import AntresolKit
import SwiftUI

/// The header of an album, playlist or artist page: the cover on the left over the
/// artwork-tinted background, and the eyebrow, huge title, context and meta lines,
/// actions and an optional description on the right.
struct CollectionHeader<Actions: View>: View {
    let card: Card
    let eyebrow: String
    var subtitle: String = ""
    var meta: String = ""
    var description: String = ""
    /// A failed action, shown in red under the buttons.
    var error: String? = nil
    @ViewBuilder let actions: () -> Actions

    private var shape: ArtworkShape { ArtworkShape(kind: card.kind) }

    private var coverWidth: CGFloat {
        shape == .poster ? 400 : 520
    }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            HeroBackground(card: card)
            HStack(alignment: .bottom, spacing: 64) {
                CardArtwork(
                    title: card.title,
                    paths: [card.poster],
                    cornerRadius: shape.cornerRadius(width: coverWidth),
                    maxPixelSize: coverWidth * shape.aspectRatio * 2,
                    showsPlaceholderTitle: shape != .circle
                )
                .frame(width: coverWidth, height: coverWidth * shape.aspectRatio)
                .shadow(color: .black.opacity(0.5), radius: 30, y: 18)

                VStack(alignment: .leading, spacing: 18) {
                    if !eyebrow.isEmpty {
                        Text(verbatim: eyebrow)
                            .font(Theme.Typography.eyebrow)
                            .tracking(2)
                            .textCase(.uppercase)
                            .foregroundStyle(Theme.Colors.label2)
                            .lineLimit(1)
                    }
                    Text(verbatim: card.title)
                        .font(Theme.Typography.heroTitle)
                        .foregroundStyle(Theme.Colors.label)
                        .lineLimit(2)
                        .minimumScaleFactor(0.5)
                        .shadow(color: .black.opacity(0.35), radius: 12)
                    if !subtitle.isEmpty {
                        Text(verbatim: subtitle)
                            .font(Theme.Typography.headline)
                            .foregroundStyle(Theme.Colors.label)
                            .lineLimit(1)
                    }
                    if !meta.isEmpty {
                        Text(verbatim: meta)
                            .font(Theme.Typography.meta)
                            .foregroundStyle(Theme.Colors.label2)
                            .lineLimit(1)
                    }
                    if !card.badges.isEmpty {
                        BadgeRow(badges: card.badges)
                    }
                    if !description.isEmpty {
                        Text(verbatim: description)
                            .font(Theme.Typography.body)
                            .foregroundStyle(Theme.Colors.label)
                            .lineLimit(3)
                            .frame(maxWidth: 1000, alignment: .leading)
                    }
                    ActionRow(content: actions)
                        .padding(.top, 18)
                    if let error {
                        Text(verbatim: error)
                            .font(Theme.Typography.meta)
                            .foregroundStyle(Theme.Colors.red)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, Theme.Layout.margin)
            .padding(.bottom, 60)
        }
        .frame(maxWidth: .infinity, minHeight: 820, alignment: .bottomLeading)
    }
}

extension EnvironmentValues {
    /// The focus of the page's primary action, set by `DetailScroll`.
    @Entry var detailPrimaryFocus: FocusState<Bool>.Binding?
}

extension View {
    /// Marks the main button of a `CollectionHeader` (Play) as the page's initial focus.
    func primaryDetailAction() -> some View {
        modifier(PrimaryDetailAction())
    }
}

private struct PrimaryDetailAction: ViewModifier {
    @Environment(\.detailPrimaryFocus) private var focus

    func body(content: Content) -> some View {
        if let focus {
            content.focused(focus)
        } else {
            content
        }
    }
}

/// Joins non-empty parts with middots: "2021 · Rock · 12 songs".
func metaLine(_ parts: [String]) -> String {
    parts.filter { !$0.isEmpty }.joined(separator: " · ")
}

/// "45 min" or "1 h 12 min" for a duration in milliseconds.
func durationText(ms: Int) -> String {
    guard ms > 0 else { return "" }
    return VideoDetailView.duration(minutes: max(1, Int((Double(ms) / 60_000).rounded())))
}
