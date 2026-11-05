import AntresolKit
import SwiftUI

/// Seasons of a series: the season pill and a row of episode cards. Clicking an episode
/// opens its page; the long-press menu plays it or toggles its watched state.
struct SeasonSection: View {
    let model: VideoDetailModel

    @Environment(AppState.self) private var appState
    @Environment(PlaybackCoordinator.self) private var playback

    var body: some View {
        if let detail = model.detail, let season = model.selectedSeason {
            VStack(alignment: .leading, spacing: 28) {
                HStack(spacing: 28) {
                    if detail.seasons.count > 1 {
                        let pill = SegmentedPill(
                            options: detail.seasons.map { SegmentedPill<Int>.Option(value: $0.id, title: Self.title(of: $0)) },
                            selection: seasonBinding
                        )
                        .padding(.vertical, 12)
                        // Many seasons scroll within the row (to the focused pill) instead
                        // of running off the screen.
                        ViewThatFits(in: .horizontal) {
                            pill
                            ScrollView(.horizontal, showsIndicators: false) { pill }
                                .scrollClipDisabled()
                        }
                    } else {
                        Text(verbatim: Self.title(of: season))
                            .font(Theme.Typography.sectionTitle)
                            .foregroundStyle(Theme.Colors.label)
                    }
                    Text(verbatim: String(localized: "\(season.episodes.count) episodes", bundle: .localized))
                        .font(Theme.Typography.meta)
                        .foregroundStyle(Theme.Colors.label3)
                        .fixedSize()
                }
                .padding(.horizontal, Theme.Layout.margin)

                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: Theme.Layout.cardSpacing) {
                        ForEach(season.episodes) { episode in
                            NavigationLink(value: Route.item(episode.card)) {
                                EpisodeCardView(episode: episode)
                            }
                            .buttonStyle(CardButtonStyle())
                            .playsOnPlayPause(episode.card)
                            .contextMenu { menu(for: episode) }
                        }
                    }
                    .padding(.horizontal, Theme.Layout.margin)
                    .padding(.vertical, 24)
                }
                .scrollClipDisabled()
                .focusSection()
            }
        }
    }

    private var seasonBinding: Binding<Int> {
        Binding(
            get: { model.selectedSeason?.id ?? 0 },
            set: { model.selectedSeasonId = $0 }
        )
    }

    @ViewBuilder
    private func menu(for episode: EpisodeCard) -> some View {
        Button {
            playback.play(episode.card, from: .resume)
        } label: {
            Label(episode.progress > 0 ? LocalizedStringKey("Resume") : LocalizedStringKey("Play"), systemImage: "play.fill")
        }
        if episode.progress > 0 {
            Button {
                playback.play(episode.card, from: .beginning)
            } label: {
                Label("Play from Beginning", systemImage: "arrow.counterclockwise")
            }
        }
        Button {
            Task { await model.setWatched(itemId: episode.id, !episode.watched, using: appState) }
        } label: {
            Label(
                episode.watched ? LocalizedStringKey("Mark as Unwatched") : LocalizedStringKey("Mark as Watched"),
                systemImage: episode.watched ? "circle" : "checkmark.circle"
            )
        }
    }

    static func title(of season: SeasonInfo) -> String {
        season.title.isEmpty ? String(localized: "Season \(season.number)", bundle: .localized) : season.title
    }
}

/// A 16:9 episode card: artwork with progress or a watched mark, then "E2 · 20 min",
/// the title and two lines of overview.
struct EpisodeCardView: View {
    let episode: EpisodeCard
    var width: CGFloat = Theme.Layout.episodeWidth

    @Environment(\.isCardFocused) private var isFocused

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CardArtwork(
                title: episode.title,
                paths: [episode.backdrop, episode.poster],
                maxPixelSize: width * 2,
                placeholderAlignment: .topLeading
            )
            .overlay {
                if episode.progress > 0, !episode.watched {
                    ZStack(alignment: .bottom) {
                        Theme.Gradients.scrim
                        ProgressBar(value: episode.progress)
                            .padding(.horizontal, 18)
                            .padding(.bottom, 16)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
                }
            }
            .overlay(alignment: .topTrailing) {
                if episode.watched {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 34, weight: .semibold))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.black, .white)
                        .shadow(color: .black.opacity(0.4), radius: 6)
                        .padding(14)
                        .accessibilityLabel(Text("Watched"))
                }
            }
            .frame(width: width, height: width * 9 / 16)
            .cardLift(isFocused: isFocused)

            VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: codeLine)
                    .font(Theme.Typography.cardMeta)
                    .foregroundStyle(Theme.Colors.label2)
                    .lineLimit(1)
                Text(verbatim: episode.title)
                    .font(Theme.Typography.cardTitle)
                    .foregroundStyle(Theme.Colors.label)
                    .lineLimit(1)
                if let overview = episode.overview, !overview.isEmpty {
                    Text(verbatim: overview)
                        .font(Theme.Typography.cardMeta)
                        .foregroundStyle(Theme.Colors.label3)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
            }
            .padding(.top, 20)
            .offset(y: isFocused ? 12 : 0)
        }
        .frame(width: width, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    /// "E2 · 20 min".
    private var codeLine: String {
        var parts = [String(localized: "E\(episode.episodeNo)", bundle: .localized)]
        if let ms = episode.durationMs, ms > 0 {
            parts.append(VideoDetailView.duration(minutes: max(1, Int((Double(ms) / 60_000).rounded()))))
        }
        return parts.joined(separator: " · ")
    }
}
