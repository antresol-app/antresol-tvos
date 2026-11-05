import AntresolKit
import SwiftUI

/// The full-bleed feature carousel at the top of Home: artwork-tinted background, an
/// eyebrow line, a huge title, a meta line and the Play / Details pills.
///
/// With several featured items it advances every 8 seconds while its buttons are not
/// focused; Left on Play and Right on Details page through them by hand. Page dots show
/// where you are, and the backgrounds cross-fade.
struct HeroView: View {
    let features: [HomeContent.Feature]

    @Environment(AppState.self) private var appState
    @Environment(PlaybackCoordinator.self) private var playback
    @State private var index = 0
    /// For a series: the episode Play starts, so the button can name it.
    @State private var seriesEpisode: EpisodeCard?
    @FocusState private var focusedButton: Control?

    private enum Control: Hashable {
        case play, details
    }

    private static let interval: Duration = .seconds(8)

    private var feature: HomeContent.Feature {
        features[min(index, features.count - 1)]
    }

    private var card: Card { feature.card }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            HeroBackground(card: card)
                .id(card.uniqueKey)
                .transition(.opacity)
            VStack(alignment: .leading, spacing: 18) {
                Text(verbatim: feature.eyebrow)
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
                if progress > 0 {
                    ProgressBar(value: progress, height: 8)
                        .frame(width: 420)
                        .padding(.top, 4)
                }
                HStack(spacing: 28) {
                    Button {
                        playback.play(seriesEpisode?.card ?? card, from: .resume)
                    } label: {
                        Label {
                            Text(verbatim: playTitle)
                        } icon: {
                            Image(systemName: "play.fill")
                        }
                    }
                    .buttonStyle(PillButtonStyle(kind: .primary))
                    .focused($focusedButton, equals: .play)
                    .onMoveCommand { if $0 == .left { page(by: -1) } }
                    NavigationLink(value: Route.item(card)) {
                        Label("Details", systemImage: "info.circle")
                    }
                    .buttonStyle(PillButtonStyle(kind: .glass))
                    .focused($focusedButton, equals: .details)
                    .onMoveCommand { if $0 == .right { page(by: 1) } }
                }
                .padding(.top, 22)
                .focusSection()
            }
            .frame(maxWidth: 1200, alignment: .leading)
            .padding(.horizontal, Theme.Layout.margin)
            .padding(.bottom, 56)
            .animation(Theme.Motion.easeOut, value: index)

            if features.count > 1 {
                pageDots
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.horizontal, Theme.Layout.margin)
                    .padding(.bottom, 80)
            }
        }
        .frame(maxWidth: .infinity, minHeight: Theme.Layout.heroHeight, maxHeight: Theme.Layout.heroHeight, alignment: .bottomLeading)
        .task(id: focusedButton == nil) {
            // Auto-advance only while the user is not on the hero's buttons.
            guard focusedButton == nil, features.count > 1 else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.interval)
                guard !Task.isCancelled else { return }
                withAnimation(Theme.Motion.slowEaseOut) { index = (index + 1) % features.count }
            }
        }
        .task(id: card.uniqueKey) { await loadSeriesEpisode() }
        .onChange(of: features) {
            if index >= features.count { index = 0 }
        }
    }

    private var pageDots: some View {
        HStack(spacing: 14) {
            ForEach(features.indices, id: \.self) { dot in
                Circle()
                    .fill(.white.opacity(dot == index ? 0.95 : 0.35))
                    .frame(width: 12, height: 12)
            }
        }
        .accessibilityElement()
        .accessibilityLabel(Text(verbatim: String(localized: "Featured \(index + 1) of \(features.count)", bundle: .localized)))
    }

    private func page(by step: Int) {
        guard features.count > 1 else { return }
        withAnimation(Theme.Motion.slowEaseOut) {
            index = (index + step + features.count) % features.count
        }
    }

    /// The series' next episode, as on its detail page.
    private func loadSeriesEpisode() async {
        seriesEpisode = nil
        guard card.kind == .series, let client = appState.client,
              let detail = try? await client.item(id: card.id), !Task.isCancelled
        else { return }
        seriesEpisode = detail.next ?? detail.seasons.first?.episodes.first
    }

    private var playTitle: String {
        if card.kind == .series {
            return VideoDetailView.playTitle(for: seriesEpisode)
        }
        return card.progress > 0 ? String(localized: "Resume", bundle: .localized) : String(localized: "Play", bundle: .localized)
    }

    private var progress: Double {
        seriesEpisode?.progress ?? card.progress
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
        let image = await ImagePipeline.shared.image(for: url, headers: client.authorizationHeaders(for: url), maxPixelSize: 96)
        guard !Task.isCancelled else { return }
        tint = image.flatMap(ImagePipeline.tintColor(of:))
    }
}
