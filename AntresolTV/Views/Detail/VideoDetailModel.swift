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
    /// The season shown on a series page.
    var selectedSeasonId: Int?
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
            selectedSeasonId = card.id
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

    var selectedSeason: SeasonInfo? {
        guard let detail else { return nil }
        return detail.seasons.first { $0.id == selectedSeasonId } ?? detail.seasons.first
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
            let detail = try await client.item(id: itemId)
            if detail.kind == .movie || detail.kind == .episode {
                progress = try? await client.progress(itemId: detail.id)
            }
            if let selectedSeasonId, !detail.seasons.contains(where: { $0.id == selectedSeasonId }) {
                self.selectedSeasonId = nil
            }
            if selectedSeasonId == nil {
                selectedSeasonId = Self.initialSeason(of: detail)
            }
            state = .loaded(detail)
        } catch {
            guard !Task.isCancelled else { return }
            let message = appState.message(for: error)
            if detail == nil, let message { state = .failed(message) }
        }
    }

    func toggleWatchlist(using appState: AppState) async {
        guard let detail, let client = appState.client else { return }
        await perform(.watchlist, appState: appState) {
            try await client.setInWatchlist(itemId: detail.id, !detail.inWatchlist)
        }
    }

    /// Marks a movie, episode, season or the whole series watched or unwatched.
    func setWatched(itemId: Int, _ watched: Bool, using appState: AppState) async {
        guard let client = appState.client else { return }
        await perform(.watched(itemId), appState: appState) {
            try await client.setWatched(itemId: itemId, watched)
        }
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

    /// The season of the episode to play next, else the first season.
    private static func initialSeason(of detail: ItemDetail) -> Int? {
        if let next = detail.next,
           let season = detail.seasons.first(where: { $0.episodes.contains { $0.id == next.id } }) {
            return season.id
        }
        return detail.seasons.first?.id
    }
}
