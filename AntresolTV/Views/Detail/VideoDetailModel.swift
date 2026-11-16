import AntresolKit
import Foundation
import Observation

/// Loads a movie, series, season or episode page and performs its actions (watchlist,
/// watched state). Season cards open their series with that season selected.
@MainActor
@Observable
final class VideoDetailModel {
    enum State {
        case loading
        case loaded(ItemDetail)
        case failed(String)
    }

    /// The card the page was opened with; shown while the detail loads.
    let card: Card
    private(set) var state: State = .loading
    /// Saved position of a movie or episode (`GET /api/progress`).
    private(set) var progress: PlaybackProgress?
    /// A series' full episode list (`/api/tracking/.../episodes`), nil when the server
    /// has none for it (older than 0.5.0, the title hidden by the age filter, an error).
    private(set) var tracking: TrackingEpisodes?
    /// The seasons and episodes of a series page: every episode when the server has the
    /// full list, the library's otherwise.
    private(set) var guide: EpisodeGuide?
    /// The season number shown on a series page.
    var selectedSeasonNumber: Int?
    /// The season item the page was opened with, chosen once the seasons are known.
    private var openedSeasonId: Int?
    /// The movie's or series' trailers (`/api/items/{id}/trailers`), empty until loaded or
    /// when there are none.
    private(set) var trailers: [Trailer] = []
    @ObservationIgnored private var trailersLoaded = false
    /// Actions in flight, so their buttons can be disabled.
    private(set) var busy: Set<Action> = []
    /// The last action error, shown under the buttons.
    private(set) var actionError: String?

    enum Action: Hashable {
        case watchlist
        case watched(Int)
    }

    init(card: Card) {
        self.card = card
        if card.kind == .season {
            openedSeasonId = card.id
        }
    }

    /// The id the page loads: a season opens its series.
    private var itemId: Int {
        card.kind == .season ? (card.seriesId ?? card.id) : card.id
    }

    var detail: ItemDetail? {
        if case .loaded(let detail) = state { return detail }
        return nil
    }

    var selectedSeason: GuideSeason? {
        guard let guide else { return nil }
        return guide.seasons.first { $0.number == selectedSeasonNumber } ?? guide.seasons.first
    }

    /// Whether a movie or episode has a saved position to resume from.
    var canResume: Bool {
        ResumePolicy.videoStartSec(progress) > 0
    }

    /// Whether a movie or episode is marked finished.
    var isWatched: Bool {
        progress?.finished ?? false
    }

    /// Whether every episode of a series is watched.
    var isSeriesWatched: Bool {
        guard let detail else { return false }
        let episodes = detail.seasons.flatMap(\.episodes)
        return !episodes.isEmpty && episodes.allSatisfy(\.watched)
    }

    /// Loads (or refreshes in place, keeping the page on screen) the detail and progress.
    func load(using appState: AppState) async {
        guard let client = appState.client else { return }
        if case .failed = state { state = .loading }
        do {
            // A movie's or episode's position is asked for beside the item, not after it.
            let asksEarly = card.kind == .movie || card.kind == .episode
            async let early: PlaybackProgress? = asksEarly ? try? await client.progress(itemId: itemId) : nil
            let detail = try await client.item(id: itemId)
            if detail.kind == .movie || detail.kind == .episode {
                // A failed request keeps the last known position (Resume stays on a
                // refresh); "no progress" is a successful, empty answer.
                let fresh = asksEarly && detail.id == itemId ? await early : try? await client.progress(itemId: detail.id)
                if let fresh { progress = fresh }
            }
            state = .loaded(detail)
            guard detail.kind == .series else {
                guide = nil
                return
            }
            // The library's seasons show at once (with the last full list on a refresh);
            // the full list replaces them when the server has one. Any failure (404/405
            // from servers before 0.5.0, a title the age filter hides) keeps the library's.
            updateGuide(detail)
            if let tmdbId = detail.tmdbId {
                let full = try? await client.trackingEpisodes(kind: .series, tmdbId: tmdbId)
                guard !Task.isCancelled, self.detail?.id == detail.id else { return }
                tracking = full
                updateGuide(detail)
            }
        } catch {
            guard !Task.isCancelled else { return }
            let message = appState.message(for: error)
            if detail == nil, let message { state = .failed(message) }
        }
    }

    /// Once per page, for a movie or series (a season page is its series'), beside the
    /// detail load. Any failure (a server without the endpoint) means no trailers.
    func loadTrailers(using appState: AppState) async {
        guard !trailersLoaded, [.movie, .series, .season].contains(card.kind), let client = appState.client else { return }
        let list = (try? await client.trailers(itemId: itemId)) ?? []
        guard !Task.isCancelled else { return }
        trailersLoaded = true
        trailers = list
    }

    private func updateGuide(_ detail: ItemDetail) {
        let guide = EpisodeGuide(library: detail.seasons, tracking: tracking, today: EpisodeGuide.day(Date()))
        self.guide = guide
        if !guide.seasons.contains(where: { $0.number == selectedSeasonNumber }) {
            selectedSeasonNumber = guide.initialSeason(preferredItemId: openedSeasonId ?? detail.next?.id)
        }
        openedSeasonId = nil
    }

    func toggleWatchlist(using appState: AppState) async {
        guard let detail, let client = appState.client else { return }
        await perform(.watchlist, appState: appState) {
            try await client.setInWatchlist(itemId: detail.id, !detail.inWatchlist)
        }
        appState.libraryChanged()
    }

    /// Marks a movie, episode, season or the whole series watched or unwatched.
    func setWatched(itemId: Int, _ watched: Bool, using appState: AppState) async {
        guard let client = appState.client else { return }
        await perform(.watched(itemId), appState: appState) {
            try await client.setWatched(itemId: itemId, watched)
        }
        // Grids and shelves redraw their watched marks.
        appState.libraryChanged()
    }

    private func perform(_ action: Action, appState: AppState, _ work: () async throws -> Void) async {
        guard !busy.contains(action) else { return }
        busy.insert(action)
        actionError = nil
        defer { busy.remove(action) }
        do {
            try await work()
            await load(using: appState)
        } catch {
            actionError = appState.message(for: error)
        }
    }
}
