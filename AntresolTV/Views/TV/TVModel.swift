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
    /// The guide's requests: one at a time, and none outlives `reloadGuide` (a page on
    /// its way when the guide is started over would be merged into the empty grid, and
    /// would keep the first window from being asked for).
    @ObservationIgnored private var guideRequests = RequestGate()

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

    /// The category list: Favourites, All, then the server's categories (AI topics,
    /// sources, groups), each with the number of channels it shows.
    private(set) var filterOptions: [ChannelFilterOption] = []
    /// The chosen filter, or All when its category is gone from the list.
    private(set) var activeFilter: ChannelFilter = .all
    /// The channels the list shows, in the server's order (favourites first when the
    /// profile wants them so).
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
        filterOptions = ChannelFilter.options(for: list.channels, server: list.categories)
        activeFilter = filter.valid(in: list.channels)
        channels = activeFilter.apply(to: list.channels)
        deriveGuide()
    }

    private func deriveGuide() {
        var grid = grid
        // the list's uploaded logos, for rows the guide sent without one
        grid.applyLogos(from: list.channels)
        // the list's order: a star changed here moves the row as it moves the list's
        guideRows = grid.rows(activeFilter, order: list.channels.map(\.id))
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
        guard let service, grid.loadedFrom == nil, let ticket = guideRequests.begin() else { return }
        do {
            let from = now.addingTimeInterval(-3600)
            let window = try await service.epg(from: from, hours: Self.windowHours)
            guard guideRequests.finish(ticket) else { return }
            grid = ChannelGuideGrid(window)
            guidePhase = .loaded
        } catch {
            guard guideRequests.finish(ticket), !Task.isCancelled else { return }
            if let message = appState?.message(for: error) { guidePhase = .failed(message) }
        }
    }

    /// The guide again from scratch (Try Again, or a long time on the page).
    func reloadGuide() async {
        guideRequests.reset()
        grid = ChannelGuideGrid()
        guidePhase = .loading
        await loadGuide()
    }

    /// The next window after what is loaded (`forward`) or the one before it.
    func loadWindow(forward: Bool, now: Date = Date()) async {
        guard let service, !guideRequests.isBusy, let loadedFrom = grid.loadedFrom, let loadedTo = grid.loadedTo else { return }
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
        guard let ticket = guideRequests.begin() else { return }
        let window = try? await service.epg(from: from, hours: hours)
        // Started over meanwhile: the page belongs to the guide that was thrown away.
        guard guideRequests.finish(ticket), let window else { return }
        grid.merge(window)
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

    /// The star in the list and the guide; with «favourites first» the list re-orders as the
    /// server will (`ChannelList.setFavorite`).
    private func setFavorite(_ favorite: Bool, _ channelId: Int) {
        list.setFavorite(favorite, channelId: channelId)
        grid.setFavorite(favorite, channelId: channelId)
    }

    /// The list's channel for a guide row (with now / next), else the row itself.
    func channel(_ id: Int) -> Channel? {
        list.channels.first { $0.id == id } ?? grid.rows.first { $0.id == id }?.channel
    }
}
