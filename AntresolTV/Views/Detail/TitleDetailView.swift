import AntresolKit
import Observation
import SwiftUI

/// Loads the page of a movie or show the library does not have (`GET /api/title/{kind}/{tmdbId}`)
/// and, for a show, its episodes (`/api/tracking/series/{tmdbId}/episodes`) when the server has them.
@MainActor
@Observable
final class TitleDetailModel {
    enum State {
        case loading
        case loaded(TitleInfo)
        case failed(String)
    }

    let ref: TitleRef
    private(set) var state: State = .loading
    /// A show's seasons and episodes, nil without a list (a movie, or none known).
    private(set) var guide: EpisodeGuide?
    var selectedSeasonNumber: Int?

    init(ref: TitleRef) {
        self.ref = ref
    }

    var info: TitleInfo? {
        if case .loaded(let info) = state { return info }
        return nil
    }

    /// What the ways are called for: the title, off the library unless the server says it has it.
    var target: WayTarget {
        info?.target ?? WayTarget(kind: ref.kind, tmdbId: ref.tmdbId, inLibrary: false)
    }

    var selectedSeason: GuideSeason? {
        guard let guide else { return nil }
        return guide.seasons.first { $0.number == selectedSeasonNumber } ?? guide.seasons.first
    }

    func load(using appState: AppState) async {
        guard let client = appState.client else { return }
        if case .failed = state { state = .loading }
        do {
            let info = try await client.titleInfo(kind: ref.kind, tmdbId: ref.tmdbId)
            guard !Task.isCancelled else { return }
            state = .loaded(info)
            guard info.kind == "series" else { return }
            // Any failure (a title the age filter hides, an older server) leaves no episode list.
            guard let tracking = try? await client.trackingEpisodes(kind: .series, tmdbId: ref.tmdbId), !Task.isCancelled else { return }
            let guide = EpisodeGuide(library: [], tracking: tracking, today: EpisodeGuide.day(Date()))
            self.guide = guide
            if !guide.seasons.contains(where: { $0.number == selectedSeasonNumber }) {
                selectedSeasonNumber = guide.initialSeason(preferredItemId: nil)
            }
        } catch {
            guard !Task.isCancelled else { return }
            let message = appState.message(for: error)
            if info == nil, let message { state = .failed(message) }
        }
    }
}

/// The page of a movie or show the library does not have: the artwork-tinted header with what the
/// server knows of it and the addons' ways («Play» runs the way chosen for the title, a chevron beside
/// it opens the menu of the ways; a way that keeps a copy has its ring), then a show's seasons with a
/// long-press menu of ways on each episode, and the cast.
struct TitleDetailView: View {
    let ref: TitleRef

    @Environment(AppState.self) private var appState
    @Environment(AddonWays.self) private var addons
    @State private var model: TitleDetailModel
    @State private var wayStates = WayStateModel()

    init(ref: TitleRef) {
        self.ref = ref
        _model = State(initialValue: TitleDetailModel(ref: ref))
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: Theme.Layout.shelfSpacing) {
                header
                if model.guide?.seasons.isEmpty == false {
                    TitleSeasonSection(model: model, card: card)
                }
                if let cast = model.info?.cast, !cast.isEmpty {
                    CastRow(cast: cast)
                }
            }
            .padding(.bottom, 100)
        }
        .ignoresSafeArea(edges: [.top, .horizontal])
        .background(Theme.Colors.background.ignoresSafeArea())
        .task { await model.load(using: appState) }
        .task(id: WayPollKey(target: model.target, snapshot: addons.snapshot, revision: addons.revision)) {
            await wayStates.poll(target: model.target, ways: addons.ways(for: model.target), using: appState)
        }
    }

    /// The title's artwork card: what the page was opened with, then what the server says.
    private var card: Card {
        guard let info = model.info else { return ref.card }
        return Card(
            id: 0, kind: ItemKind(rawValue: info.kind), title: info.title.isEmpty ? ref.title : info.title,
            year: info.year ?? ref.year, poster: info.poster.isEmpty ? ref.poster : info.poster,
            backdrop: info.backdrop, onServer: info.inLibrary
        )
    }

    private var failureMessage: String? {
        if case .failed(let message) = model.state { return message }
        return nil
    }

    private var header: some View {
        ZStack(alignment: .bottomLeading) {
            HeroBackground(card: card)
            VStack(alignment: .leading, spacing: 20) {
                Text(verbatim: eyebrow)
                    .font(Theme.Typography.eyebrow)
                    .tracking(2)
                    .textCase(.uppercase)
                    .foregroundStyle(Theme.Colors.label2)
                    .lineLimit(1)
                Text(verbatim: card.title)
                    .font(Theme.Typography.heroTitle)
                    .foregroundStyle(Theme.Colors.label)
                    .lineLimit(2)
                    .minimumScaleFactor(0.6)
                    .shadow(color: .black.opacity(0.35), radius: 12)
                    .frame(maxWidth: 1400, alignment: .leading)
                if !metaLine.isEmpty {
                    Text(verbatim: metaLine)
                        .font(Theme.Typography.meta)
                        .foregroundStyle(Theme.Colors.label2)
                        .lineLimit(1)
                }
                if let overview = overview, !overview.isEmpty {
                    Text(verbatim: overview)
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.Colors.label)
                        .lineLimit(3)
                        .frame(maxWidth: 1100, alignment: .leading)
                        .padding(.top, 4)
                }
                actions
                    .padding(.top, 16)
                if let message = failureMessage {
                    Text(verbatim: message)
                        .font(Theme.Typography.meta)
                        .foregroundStyle(Theme.Colors.red)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Theme.Layout.margin)
            .padding(.bottom, 40)
        }
        .frame(
            maxWidth: .infinity,
            minHeight: headerHeight,
            maxHeight: headerHeight,
            alignment: .bottomLeading
        )
    }

    /// A show's header is shorter so the season row peeks in.
    private var headerHeight: CGFloat {
        ref.kind == "series" ? Theme.Layout.detailHeaderHeight - 100 : Theme.Layout.detailHeaderHeight
    }

    private var overview: String? {
        model.info?.overview
    }

    private var eyebrow: String {
        ref.kind == "series" ? String(localized: "Show", bundle: .localized) : ItemKind.movie.displayName
    }

    private var metaLine: String {
        var parts: [String] = []
        if let year = card.year { parts.append(String(year)) }
        if let info = model.info {
            if info.kind == "series", !info.seasons.isEmpty {
                parts.append(String(localized: "\(info.seasons.count) seasons", bundle: .localized))
            }
            if let runtime = info.runtime, runtime > 0 {
                parts.append(VideoDetailView.duration(minutes: runtime))
            }
            if let rating = info.rating, !rating.isEmpty { parts.append(rating) }
            parts.append(contentsOf: info.genres.prefix(3))
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var actions: some View {
        ActionRow {
            WayWatchButtons(target: model.target, card: card, hasPlay: false)
            WayKeepButtons(target: model.target, card: card, states: wayStates)
            // The library has it after all (added since the search): its own page plays it.
            if let info = model.info, info.inLibrary, let itemId = info.libraryItemId, itemId > 0 {
                NavigationLink(value: Route.item(Card(id: itemId, kind: ItemKind(rawValue: info.kind), title: card.title, poster: card.poster))) {
                    Label("Details", systemImage: "info.circle")
                }
                .buttonStyle(PillButtonStyle(kind: .glass))
            }
            if failureMessage != nil {
                Button {
                    Task { await model.load(using: appState) }
                } label: {
                    Label("Try Again", systemImage: "arrow.clockwise")
                }
                .buttonStyle(PillButtonStyle(kind: .glass))
            }
        }
    }
}

/// A show's seasons: the season pill and a row of episode cards. Select plays an episode with the
/// way chosen for the show (else the first that watches), as Play would; a long press opens the
/// menu of the ways offered for it. An episode still to air has none.
private struct TitleSeasonSection: View {
    let model: TitleDetailModel
    let card: Card

    @Environment(AppState.self) private var appState
    @Environment(PlaybackCoordinator.self) private var playback
    @Environment(AddonWays.self) private var addons

    var body: some View {
        if let guide = model.guide, let season = model.selectedSeason {
            VStack(alignment: .leading, spacing: 28) {
                HStack(spacing: 28) {
                    if guide.seasons.count > 1 {
                        let pill = SegmentedPill(
                            options: guide.seasons.map { SegmentedPill<Int>.Option(value: $0.number, title: SeasonSection.title(of: $0)) },
                            selection: seasonBinding
                        )
                        .padding(.vertical, 12)
                        ViewThatFits(in: .horizontal) {
                            pill
                            ScrollView(.horizontal, showsIndicators: false) { pill }
                                .scrollClipDisabled()
                        }
                    } else {
                        Text(verbatim: SeasonSection.title(of: season))
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
                            cell(for: episode)
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

    private func cell(for episode: GuideEpisode) -> some View {
        let target = wayTarget(for: episode)
        return Button {
            if let target, let way = addons.menu(for: target)?.defaultWay {
                addons.start(WayLaunch(way: way, target: target, card: wayCard(for: episode)), choose: false, appState: appState, playback: playback)
            }
        } label: {
            EpisodeCardView(guide: episode)
                .wayBusy(target.map { addons.isRunning(for: $0) } ?? false)
        }
        .buttonStyle(CardButtonStyle())
        .contextMenu {
            if let target {
                EpisodeWayMenu(target: target, card: wayCard(for: episode))
            }
        }
    }

    private func wayTarget(for episode: GuideEpisode) -> WayTarget? {
        guard episode.state != .upcoming else { return nil }
        return model.target.episode(season: episode.season, episode: episode.number, inLibrary: episode.card != nil)
    }

    /// The show's card with the episode's code as its context line.
    private func wayCard(for episode: GuideEpisode) -> Card {
        var card = card
        card.subtitle = String(localized: "S\(episode.season), E\(episode.number)", bundle: .localized)
        return card
    }

    private var seasonBinding: Binding<Int> {
        Binding(
            get: { model.selectedSeason?.number ?? 0 },
            set: { model.selectedSeasonNumber = $0 }
        )
    }
}
