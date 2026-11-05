import AntresolKit
import SwiftUI

/// The page of a movie, series, season or episode: an artwork-tinted header with the
/// eyebrow, title, meta line, badges, overview and actions; then seasons and episodes
/// (series), cast, and an About panel with the file details.
struct VideoDetailView: View {
    let card: Card

    @Environment(AppState.self) private var appState
    @Environment(PlaybackCoordinator.self) private var playback
    @State private var model: VideoDetailModel
    @FocusState private var focusedButton: HeaderButton?
    @Environment(\.claimsFocusOnAppear) private var claimsFocusOnAppear
    @State private var didClaimFocus = false
    @State private var choosingVersion = false

    enum HeaderButton: Hashable {
        case play
    }

    init(card: Card) {
        self.card = card
        _model = State(initialValue: VideoDetailModel(card: card))
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: Theme.Layout.shelfSpacing) {
                header
                if let detail = model.detail {
                    if detail.kind == .series, !detail.seasons.isEmpty {
                        SeasonSection(model: model)
                    }
                    if !detail.cast.isEmpty {
                        CastRow(cast: detail.cast)
                    }
                    AboutPanel(detail: detail)
                }
            }
            .padding(.bottom, 100)
        }
        .ignoresSafeArea(edges: [.top, .horizontal])
        .background(Theme.Colors.background.ignoresSafeArea())
        .defaultFocus($focusedButton, .play)
        .task {
            // Opened from outside (Top Shelf): focus is still on the tab bar, where Menu
            // would leave the app, so move it to Play once the page is on screen.
            guard claimsFocusOnAppear, !didClaimFocus else { return }
            didClaimFocus = true
            try? await Task.sleep(for: .milliseconds(400))
            focusedButton = .play
        }
        .task(id: card.uniqueKey) { await model.load(using: appState) }
        .onChange(of: playback.completedSessions) {
            Task { await model.load(using: appState) }
        }
    }

    /// The loaded detail's card, or the card the page was opened with.
    private var shownCard: Card {
        model.detail?.card ?? card
    }

    private var isSeries: Bool {
        shownCard.kind == .series || card.kind == .season
    }

    // MARK: Header

    private var header: some View {
        ZStack(alignment: .bottomLeading) {
            HeroBackground(card: shownCard)
            VStack(alignment: .leading, spacing: 20) {
                if !eyebrow.isEmpty {
                    Text(verbatim: eyebrow)
                        .font(Theme.Typography.eyebrow)
                        .tracking(2)
                        .textCase(.uppercase)
                        .foregroundStyle(Theme.Colors.label2)
                        .lineLimit(1)
                }
                Text(verbatim: shownCard.title)
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
                if !shownCard.badges.isEmpty {
                    BadgeRow(badges: shownCard.badges)
                }
                if let overview = model.detail?.overview, !overview.isEmpty {
                    Text(verbatim: overview)
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.Colors.label)
                        .lineLimit(3)
                        .frame(maxWidth: 1100, alignment: .leading)
                        .padding(.top, 4)
                }
                if let resume = resumeInfo {
                    HStack(spacing: 20) {
                        ProgressBar(value: resume.fraction, height: 8)
                            .frame(width: 360)
                        Text(verbatim: resume.label)
                            .font(Theme.Typography.meta)
                            .foregroundStyle(Theme.Colors.label2)
                    }
                    .padding(.top, 4)
                }
                actions
                    .padding(.top, 16)
                if let message = model.actionError ?? failureMessage {
                    Text(verbatim: message)
                        .font(Theme.Typography.meta)
                        .foregroundStyle(Theme.Colors.red)
                }
            }
            .frame(maxWidth: 1400, alignment: .leading)
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

    /// Series pages keep the header shorter so the season row peeks in.
    private var headerHeight: CGFloat {
        isSeries ? Theme.Layout.detailHeaderHeight - 100 : Theme.Layout.detailHeaderHeight
    }

    private var failureMessage: String? {
        if case .failed(let message) = model.state { return message }
        return nil
    }

    private var eyebrow: String {
        if shownCard.kind == .episode, !shownCard.subtitle.isEmpty {
            return shownCard.subtitle
        }
        if shownCard.kind == .series {
            return String(localized: "TV Show", bundle: .localized)
        }
        return shownCard.kind.displayName
    }

    private var metaLine: String {
        var parts: [String] = []
        if let year = shownCard.year { parts.append(String(year)) }
        if let detail = model.detail {
            if detail.kind == .series, !detail.seasons.isEmpty {
                parts.append(String(localized: "\(detail.seasons.count) seasons", bundle: .localized))
            }
            if let runtime = detail.runtime, runtime > 0 {
                parts.append(Self.duration(minutes: runtime))
            } else if let ms = detail.primaryFile?.durationMs, ms > 0 {
                parts.append(Self.duration(minutes: max(1, Int((Double(ms) / 60_000).rounded()))))
            }
            if let rating = detail.rating, !rating.isEmpty { parts.append(rating) }
            parts.append(contentsOf: detail.genres.prefix(3))
        } else if !shownCard.subtitle.isEmpty, shownCard.kind != .episode {
            parts.append(shownCard.subtitle)
        }
        return parts.joined(separator: " · ")
    }

    private var resumeInfo: (fraction: Double, label: String)? {
        guard model.canResume, let progress = model.progress, progress.durationMs > 0 else { return nil }
        let remaining = max(0, progress.durationMs - progress.positionMs)
        let minutes = max(1, Int((Double(remaining) / 60_000).rounded()))
        return (Double(progress.positionMs) / Double(progress.durationMs), String(localized: "\(minutes) min left", bundle: .localized))
    }

    static func duration(minutes: Int) -> String {
        let hours = minutes / 60
        let rest = minutes % 60
        if hours > 0 {
            return rest > 0 ? String(localized: "\(hours) h \(rest) min", bundle: .localized) : String(localized: "\(hours) h", bundle: .localized)
        }
        return String(localized: "\(minutes) min", bundle: .localized)
    }

    // MARK: Actions

    @ViewBuilder
    private var actions: some View {
        HStack(spacing: 24) {
            if isSeries {
                seriesActions
            } else {
                playableActions
            }
            if model.detail == nil, failureMessage != nil {
                Button {
                    Task { await model.load(using: appState) }
                } label: {
                    Label("Try Again", systemImage: "arrow.clockwise")
                }
                .buttonStyle(PillButtonStyle(kind: .glass))
            }
        }
        .focusSection()
    }

    @ViewBuilder
    private var playableActions: some View {
        let detail = model.detail
        let hasFile = detail.map { !$0.files.isEmpty } ?? true
        Button {
            playback.play(shownCard, from: .resume)
        } label: {
            Label(model.canResume ? LocalizedStringKey("Resume") : LocalizedStringKey("Play"), systemImage: "play.fill")
        }
        .buttonStyle(PillButtonStyle(kind: .primary))
        .focused($focusedButton, equals: .play)
        .disabled(!hasFile)

        if model.canResume {
            Button {
                playback.play(shownCard, from: .beginning)
            } label: {
                Label("Restart", systemImage: "arrow.counterclockwise")
            }
            .buttonStyle(PillButtonStyle(kind: .glass))
        }

        if let files = detail?.files, files.count > 1 {
            Button {
                choosingVersion = true
            } label: {
                Label("Versions", systemImage: "square.stack")
            }
            .buttonStyle(PillButtonStyle(kind: .glass))
            .confirmationDialog("Play Version", isPresented: $choosingVersion, titleVisibility: .visible) {
                ForEach(files) { file in
                    Button(Self.versionLabel(file)) {
                        playback.play(shownCard, from: .resume, fileId: file.id)
                    }
                }
                Button("Cancel", role: .cancel) {}
            }
        }

        if shownCard.kind == .movie {
            watchlistButton
        }

        if let detail {
            Button {
                Task { await model.setWatched(itemId: detail.id, !model.isWatched, using: appState) }
            } label: {
                Label(model.isWatched ? LocalizedStringKey("Watched") : LocalizedStringKey("Mark as Watched"), systemImage: model.isWatched ? "checkmark.circle.fill" : "checkmark.circle")
            }
            .buttonStyle(PillButtonStyle(kind: .glass))
            .disabled(model.busy.contains(.watched(detail.id)))
        }

        if shownCard.kind == .episode, let series = seriesCard {
            NavigationLink(value: Route.item(series)) {
                Label("Go to Show", systemImage: "tv")
            }
            .buttonStyle(PillButtonStyle(kind: .glass))
        }
    }

    @ViewBuilder
    private var seriesActions: some View {
        let next = nextEpisode
        Button {
            playback.play(next?.card ?? shownCard, from: .resume)
        } label: {
            Label {
                Text(verbatim: Self.playTitle(for: next))
            } icon: {
                Image(systemName: "play.fill")
            }
        }
        .buttonStyle(PillButtonStyle(kind: .primary))
        .focused($focusedButton, equals: .play)
        .disabled(model.detail != nil && next == nil)

        watchlistButton

        if let detail = model.detail {
            let watched = model.isSeriesWatched
            Button {
                Task { await model.setWatched(itemId: detail.id, !watched, using: appState) }
            } label: {
                Label(watched ? LocalizedStringKey("Watched") : LocalizedStringKey("Mark as Watched"), systemImage: watched ? "checkmark.circle.fill" : "checkmark.circle")
            }
            .buttonStyle(PillButtonStyle(kind: .glass))
            .disabled(model.busy.contains(.watched(detail.id)))
        }
    }

    private var watchlistButton: some View {
        let inWatchlist = model.detail?.inWatchlist ?? false
        return Button {
            Task { await model.toggleWatchlist(using: appState) }
        } label: {
            Label("Watchlist", systemImage: inWatchlist ? "checkmark" : "plus")
        }
        .buttonStyle(PillButtonStyle(kind: .glass))
        .disabled(model.detail == nil || model.busy.contains(.watchlist))
        .accessibilityValue(Text(inWatchlist ? LocalizedStringKey("In Watchlist") : LocalizedStringKey("Not in Watchlist")))
    }

    /// The server's next episode, else the first one.
    private var nextEpisode: EpisodeCard? {
        guard let detail = model.detail else { return nil }
        return detail.next ?? detail.seasons.first?.episodes.first
    }

    /// "Play S1, E1" or "Resume S1, E2" for a series' next episode (Home's hero too).
    static func playTitle(for episode: EpisodeCard?) -> String {
        guard let episode else { return String(localized: "Play", bundle: .localized) }
        let code = String(localized: "S\(episode.seasonNo), E\(episode.episodeNo)", bundle: .localized)
        return episode.progress > 0
            ? String(localized: "Resume \(code)", bundle: .localized)
            : String(localized: "Play \(code)", bundle: .localized)
    }

    /// "4K · Movie.Name.2160p.mkv", for the version picker.
    static func versionLabel(_ file: FileInfo) -> String {
        [file.resolution, file.name].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " · ")
    }

    /// The parent show of an episode, for "Go to Show".
    private var seriesCard: Card? {
        guard let seriesId = shownCard.seriesId else { return nil }
        let name = shownCard.subtitle.components(separatedBy: " · ").first ?? ""
        return Card(id: seriesId, kind: .series, title: name, poster: shownCard.poster)
    }
}
