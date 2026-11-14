import AntresolKit
import SwiftUI

/// Seasons of a series: the season pill and a row of episode cards. Clicking a downloaded
/// episode opens its page; the long-press menu plays it or toggles its watched state.
/// When the server has the series' full episode list, episodes not in the library show
/// dimmed and marked (clicking one says so), and those still to air greyed with their date.
struct SeasonSection: View {
    let model: VideoDetailModel

    @Environment(AppState.self) private var appState
    @Environment(PlaybackCoordinator.self) private var playback

    var body: some View {
        if let guide = model.guide, let season = model.selectedSeason {
            VStack(alignment: .leading, spacing: 28) {
                HStack(spacing: 28) {
                    if guide.seasons.count > 1 {
                        let pill = SegmentedPill(
                            options: guide.seasons.map { SegmentedPill<Int>.Option(value: $0.number, title: Self.title(of: $0)) },
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
                            cell(for: episode, marked: guide.isFull)
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

    @ViewBuilder
    private func cell(for episode: GuideEpisode, marked: Bool) -> some View {
        if let card = episode.card {
            NavigationLink(value: Route.item(card.card)) {
                EpisodeCardView(episode: card, state: marked ? .downloaded : nil)
            }
            .buttonStyle(CardButtonStyle())
            .playsOnPlayPause(card.card)
            .contextMenu { menu(for: card) }
        } else {
            // Not in the library: focusable, so the row scrolls to it, but nothing plays.
            Button {
                if episode.state == .missing {
                    appState.showNotice(String(localized: "Not in the library", bundle: .localized))
                }
            } label: {
                EpisodeCardView(guide: episode)
            }
            .buttonStyle(CardButtonStyle())
        }
    }

    private var seasonBinding: Binding<Int> {
        Binding(
            get: { model.selectedSeason?.number ?? 0 },
            set: { model.selectedSeasonNumber = $0 }
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

    static func title(of season: GuideSeason) -> String {
        if !season.title.isEmpty { return season.title }
        if season.number == 0 { return String(localized: "Specials", bundle: .localized) }
        return String(localized: "Season \(season.number)", bundle: .localized)
    }
}

/// A 16:9 episode card: artwork with progress or a watched mark, then "E2 · 20 min",
/// the title and two lines of overview. On a full episode list the meta line carries
/// "Downloaded", "Not downloaded" or "Airs 1 Dec", and the last two are dimmed.
struct EpisodeCardView: View {
    let title: String
    let artwork: [String]
    let episodeNo: Int
    let durationMs: Int?
    let overview: String?
    let progress: Double
    let watched: Bool
    /// nil on the library's own list: no mark.
    let state: GuideEpisode.State?
    /// The air date of an upcoming episode.
    let airDay: Date?
    var width: CGFloat = Theme.Layout.episodeWidth

    @Environment(\.isCardFocused) private var isFocused
    @Environment(\.locale) private var locale

    /// A library episode.
    init(episode: EpisodeCard, state: GuideEpisode.State? = nil, width: CGFloat = Theme.Layout.episodeWidth) {
        title = episode.title
        artwork = [episode.backdrop, episode.poster]
        episodeNo = episode.episodeNo
        durationMs = episode.durationMs
        overview = episode.overview
        progress = episode.progress
        watched = episode.watched
        self.state = state
        airDay = nil
        self.width = width
    }

    /// An episode not in the library.
    init(guide episode: GuideEpisode, width: CGFloat = Theme.Layout.episodeWidth) {
        title = episode.name.isEmpty ? String(localized: "E\(episode.number)", bundle: .localized) : episode.name
        artwork = []
        episodeNo = episode.number
        durationMs = nil
        overview = nil
        progress = 0
        watched = episode.watched
        state = episode.state
        airDay = episode.airDay()
        self.width = width
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CardArtwork(
                title: title,
                paths: artwork,
                maxPixelSize: width * 2,
                placeholderAlignment: .topLeading
            )
            .overlay {
                if progress > 0, !watched {
                    ZStack(alignment: .bottom) {
                        Theme.Gradients.scrim
                        ProgressBar(value: progress)
                            .padding(.horizontal, 18)
                            .padding(.bottom, 16)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
                }
            }
            .overlay(alignment: .topTrailing) {
                if watched {
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
                HStack(spacing: 10) {
                    Text(verbatim: codeLine)
                        .font(Theme.Typography.cardMeta)
                        .foregroundStyle(Theme.Colors.label2)
                        .lineLimit(1)
                    if let mark {
                        BadgeRow(badges: [mark])
                    }
                }
                Text(verbatim: title)
                    .font(Theme.Typography.cardTitle)
                    .foregroundStyle(Theme.Colors.label)
                    .lineLimit(1)
                if let overview, !overview.isEmpty {
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
        .opacity(dimming)
        .accessibilityElement(children: .combine)
    }

    /// Not downloaded is dimmer than downloaded; still to air is greyed further. Focus
    /// lifts both a little so the focused card stays readable.
    private var dimming: Double {
        switch state {
        case .missing: return isFocused ? 0.8 : 0.55
        case .upcoming: return isFocused ? 0.6 : 0.35
        default: return 1
        }
    }

    /// "Downloaded", "Not downloaded", "Airs 1 Dec".
    private var mark: String? {
        switch state {
        case .downloaded: return String(localized: "Downloaded", bundle: .localized)
        case .missing: return String(localized: "Not downloaded", bundle: .localized)
        case .upcoming:
            guard let airDay else { return String(localized: "Upcoming", bundle: .localized) }
            let sameYear = Calendar.current.component(.year, from: airDay) == Calendar.current.component(.year, from: Date())
            let style = sameYear
                ? Date.FormatStyle(date: .omitted, time: .omitted).day().month(.abbreviated)
                : Date.FormatStyle(date: .omitted, time: .omitted).day().month(.abbreviated).year()
            return String(localized: "Airs \(airDay.formatted(style.locale(locale)))", bundle: .localized)
        case nil: return nil
        }
    }

    /// "E2 · 20 min".
    private var codeLine: String {
        var parts = [String(localized: "E\(episodeNo)", bundle: .localized)]
        if let ms = durationMs, ms > 0 {
            parts.append(VideoDetailView.duration(minutes: max(1, Int((Double(ms) / 60_000).rounded()))))
        }
        return parts.joined(separator: " · ")
    }
}
