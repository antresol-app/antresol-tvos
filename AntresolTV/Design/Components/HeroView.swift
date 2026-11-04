import AntresolKit
import SwiftUI

/// The full-bleed feature banner at the top of Home: artwork-tinted background, an eyebrow
/// line, a huge title, a meta line and the Play / Details pills.
struct HeroView: View {
    let card: Card
    /// Small caps line above the title, e.g. "NEW IN LIBRARY · MOVIE".
    let eyebrow: String

    @Environment(PlaybackCoordinator.self) private var playback

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            HeroBackground(card: card)
            VStack(alignment: .leading, spacing: 18) {
                Text(verbatim: eyebrow)
                    .font(Theme.Typography.eyebrow)
                    .tracking(2)
                    .textCase(.uppercase)
                    .foregroundStyle(Theme.Colors.label2)
                Text(verbatim: card.title)
                    .font(Theme.Typography.heroTitle)
                    .foregroundStyle(Theme.Colors.label)
                    .lineLimit(2)
                    .minimumScaleFactor(0.6)
                    .shadow(color: .black.opacity(0.35), radius: 12)
                if !metaLine.isEmpty {
                    Text(verbatim: metaLine)
                        .font(Theme.Typography.meta)
                        .foregroundStyle(Theme.Colors.label2)
                        .lineLimit(1)
                }
                if card.progress > 0 {
                    ProgressBar(value: card.progress, height: 8)
                        .frame(width: 420)
                        .padding(.top, 4)
                }
                HStack(spacing: 28) {
                    Button {
                        playback.play(card)
                    } label: {
                        Label(card.progress > 0 ? LocalizedStringKey("Resume") : LocalizedStringKey("Play"), systemImage: "play.fill")
                    }
                    .buttonStyle(PillButtonStyle(kind: .primary))
                    NavigationLink(value: Route.item(card)) {
                        Label("Details", systemImage: "info.circle")
                    }
                    .buttonStyle(PillButtonStyle(kind: .glass))
                }
                .padding(.top, 22)
                .focusSection()
            }
            .frame(maxWidth: 1200, alignment: .leading)
            .padding(.horizontal, Theme.Layout.margin)
            .padding(.bottom, 56)
        }
        .frame(maxWidth: .infinity, minHeight: Theme.Layout.heroHeight, maxHeight: Theme.Layout.heroHeight, alignment: .bottomLeading)
    }

    /// Year, context line and the first badges, joined with middots.
    private var metaLine: String {
        var parts: [String] = []
        if let year = card.year { parts.append(String(year)) }
        if !card.subtitle.isEmpty { parts.append(card.subtitle) }
        parts.append(contentsOf: card.badges.prefix(2))
        return parts.joined(separator: " · ")
    }
}

/// The hero backdrop: a glow tinted with the artwork's average colour, the backdrop image
/// when there is one, and gradients that fade it into the black page and keep the text
/// on the left legible.
struct HeroBackground: View {
    let card: Card

    @Environment(AppState.self) private var appState
    @State private var tint: Color?

    var body: some View {
        ZStack {
            Theme.Colors.background
            RadialGradient(
                colors: [glow.opacity(0.95), glow.opacity(0.4), .clear],
                center: UnitPoint(x: 0.7, y: 0.15),
                startRadius: 0,
                endRadius: 1300
            )
            if !card.backdrop.isEmpty {
                RemoteImage(path: card.backdrop, maxPixelSize: 1920)
                    .mask(
                        LinearGradient(
                            stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.55), .init(color: .clear, location: 1)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
            }
            LinearGradient(
                colors: [.black.opacity(0.8), .black.opacity(0.25), .clear],
                startPoint: .leading,
                endPoint: UnitPoint(x: 0.75, y: 0.5)
            )
            LinearGradient(
                stops: [.init(color: .clear, location: 0.5), .init(color: .black, location: 1)],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .animation(Theme.Motion.slowEaseOut, value: tint)
        .task(id: tintSource) { await loadTint() }
        .accessibilityHidden(true)
    }

    private var glow: Color {
        tint ?? Theme.tint(for: card.title)
    }

    /// Backdrop when there is one, otherwise the poster.
    private var tintSource: String {
        card.backdrop.isEmpty ? card.poster : card.backdrop
    }

    private func loadTint() async {
        guard let client = appState.client, let url = client.urls.image(tintSource) else {
            tint = nil
            return
        }
        let image = await ImagePipeline.shared.image(for: url, headers: client.authorizationHeaders, maxPixelSize: 96)
        guard !Task.isCancelled else { return }
        tint = image.flatMap(ImagePipeline.tintColor(of:))
    }
}
