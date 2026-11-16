import AntresolKit
import Foundation
import Observation

/// The TV tab's state: the one channel list (with the last channel), the filter and view
/// the viewer chose, the guide's programmes as loaded so far and the favourites. Every
/// request goes through `ChannelService` (TV is TV: favourites and the last channel are
/// the only writes).
@MainActor
@Observable
final class TVModel {
    enum Mode: String {
        case channels
        case guide
    }

    enum Phase: Equatable {
        case loading
        case loaded
        case failed(String)
    }

    private(set) var phase: Phase = .loading
    private(set) var list = ChannelList(channels: []) {
        didSet { derive() }
    }
    private(set) var grid = ChannelGuideGrid() {
        didSet { deriveGuide() }
    }
    private(set) var guidePhase: Phase = .loading
    /// A guide window is being fetched.
    private(set) var isLoadingWindow = false

    var mode: Mode {
        didSet { defaults.set(mode.rawValue, forKey: Self.modeKey) }
    }

    var filter: ChannelFilter {
        didSet {
            defaults.set(filter.storageKey, forKey: Self.filterKey)
            derive()
        }
    }

    // Derived from `list`, `grid` and `filter` when one of them changes (`derive`,
    // `deriveGuide`), not on every read: the views read them for each row and block they
    // draw, on every focus move.

    /// The filters the list offers.
    private(set) var filters: [ChannelFilter] = []
    /// The chosen filter, or All when its theme is gone from the list.
    private(set) var activeFilter: ChannelFilter = .all
    /// The channels the list shows.
    private(set) var channels: [Channel] = []
    /// The guide's rows for the filter.
    private(set) var guideRows: [ChannelEPG] = []
    /// The guide's time scale, fitted to the typical length of the loaded programmes.
    private(set) var guideScale = GuideScale.fitting(typicalLength: nil)

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private weak var appState: AppState?

    private static let modeKey = "tv.mode"
    private static let filterKey = "tv.filter"
    /// How far back the guide goes, and how far ahead (the server keeps 48 h).
    static let guidePast: TimeInterval = 3 * 3600
    static let guideFuture: TimeInterval = 47 * 3600
    /// One guide request covers this many hours.
    static let windowHours = 6

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        mode = Mode(rawValue: defaults.string(forKey: Self.modeKey) ?? "") ?? .channels
        filter = ChannelFilter(storageKey: defaults.string(forKey: Self.filterKey) ?? "")
        derive()
    }

    func attach(_ appState: AppState) {
        self.appState = appState
    }

    private var service: ChannelService? {
        appState?.client.map(ChannelService.init(client:))
    }

    private func derive() {
        filters = ChannelFilter.options(for: list.channels)
        activeFilter = filters.contains(filter) ? filter : .all
        channels = activeFilter.apply(to: list.channels)
        deriveGuide()
    }

    private func deriveGuide() {
        var grid = grid
        // the list's uploaded logos, for rows the guide sent without one
        grid.applyLogos(from: list.channels)
        guideRows = grid.rows(activeFilter)
        guideScale = GuideScale.fitting(typicalLength: ChannelGuideGrid.typicalLength(of: grid.rows))
    }

    // MARK: - Loading

    /// Fetches the list (now / next, favourites, the last channel); a failed refresh keeps
    /// what is shown.
    func refresh() async {
        guard let service else { return }
        do {
            list = try await service.list()
            phase = .loaded
        } catch {
            guard !Task.isCancelled else { return }
            let message = appState?.message(for: error)
            if phase != .loaded, let message { phase = .failed(message) }
        }
    }

    /// The guide's first window: from a little before now.
    func loadGuide(now: Date = Date()) async {
        guard let service, grid.loadedFrom == nil, !isLoadingWindow else { return }
        isLoadingWindow = true
        defer { isLoadingWindow = false }
        do {
            let from = now.addingTimeInterval(-3600)
            grid = ChannelGuideGrid(try await service.epg(from: from, hours: Self.windowHours))
            guidePhase = .loaded
        } catch {
            guard !Task.isCancelled else { return }
            if let message = appState?.message(for: error) { guidePhase = .failed(message) }
        }
    }

    /// The guide again from scratch (Try Again, or a long time on the page).
    func reloadGuide() async {
        grid = ChannelGuideGrid()
        guidePhase = .loading
        await loadGuide()
    }

    /// The next window after what is loaded (`forward`) or the one before it.
    func loadWindow(forward: Bool, now: Date = Date()) async {
        guard let service, !isLoadingWindow, let loadedFrom = grid.loadedFrom, let loadedTo = grid.loadedTo else { return }
        let from: Date
        let hours: Int
        if forward {
            guard loadedTo < now.addingTimeInterval(Self.guideFuture) else { return }
            from = loadedTo
            hours = Self.windowHours
        } else {
            let earliest = now.addingTimeInterval(-Self.guidePast)
            guard loadedFrom > earliest.addingTimeInterval(60) else { return }
            from = max(earliest, loadedFrom.addingTimeInterval(-Double(Self.windowHours) * 3600))
            hours = max(1, Int((loadedFrom.timeIntervalSince(from) / 3600).rounded(.up)))
        }
        isLoadingWindow = true
        defer { isLoadingWindow = false }
        if let window = try? await service.epg(from: from, hours: hours) {
            grid.merge(window)
        }
    }

    /// Whether the guide may still page back (it shows from three hours ago).
    func canLoadEarlier(now: Date = Date()) -> Bool {
        guard let loadedFrom = grid.loadedFrom else { return false }
        return loadedFrom > now.addingTimeInterval(-Self.guidePast).addingTimeInterval(60)
    }

    // MARK: - Favourites

    /// Stars or unstars a channel: shown at once, put back when the server says no.
    func toggleFavorite(_ channelId: Int) async {
        guard let service else { return }
        let favorite = !(list.channels.first { $0.id == channelId }?.favorite ?? grid.rows.first { $0.id == channelId }?.favorite ?? false)
        setFavorite(favorite, channelId)
        do {
            try await service.setFavorite(channelId: channelId, favorite)
        } catch {
            setFavorite(!favorite, channelId)
            _ = appState?.message(for: error)
        }
    }

    func isFavorite(_ channelId: Int) -> Bool {
        list.channels.first { $0.id == channelId }?.favorite ?? grid.rows.first { $0.id == channelId }?.favorite ?? false
    }

    private func setFavorite(_ favorite: Bool, _ channelId: Int) {
        if let index = list.channels.firstIndex(where: { $0.id == channelId }) {
            list.channels[index].favorite = favorite
        }
        grid.setFavorite(favorite, channelId: channelId)
    }

    /// The list's channel for a guide row (with now / next), else the row itself.
    func channel(_ id: Int) -> Channel? {
        list.channels.first { $0.id == id } ?? grid.rows.first { $0.id == id }?.channel
    }
}
