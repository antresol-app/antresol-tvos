import AntresolKit
import Foundation
import Observation

/// A way called for a title (or one of its episodes), with the card it is shown over: the chooser's
/// and the player's backdrop and name.
struct WayLaunch: Identifiable, Hashable {
    let id = UUID()
    let way: AddonWay
    let target: WayTarget
    let card: Card
}

/// A title off the library that a page opens by its TMDB id: what a search result of an addon
/// shows until the page has loaded.
struct TitleRef: Hashable {
    let kind: String
    let tmdbId: Int
    let title: String
    let year: Int?
    let poster: String

    init(_ found: AddonTitle) {
        kind = found.kind
        tmdbId = found.tmdbId
        title = found.title
        year = found.year
        poster = found.poster
    }

    /// The artwork card of the title.
    var card: Card {
        Card(id: 0, kind: ItemKind(rawValue: kind), title: title, year: year, poster: poster, onServer: false)
    }
}

/// The ways the signed-in profile's addons offer, found once per sign-in (`AddonCatalog`), and the
/// chooser they open. Nothing is offered without addons, to a kid's profile, or when the server
/// answers nothing: the pages then show no new button.
@MainActor
@Observable
final class AddonWays {
    /// What the addons offer, as of the last `load`.
    private(set) var snapshot = AddonCatalogSnapshot.empty
    /// The chooser on screen, if any.
    var sheet: WayLaunch?
    /// The run in flight: one at a time, and only the way's button on the title or episode it was
    /// started for shows it (`isRunning`); every other press waits.
    private(set) var runs = WayRunGate()
    /// Goes up when a way did something whose state the pages show (a copy begun, cancelled).
    private(set) var revision = 0

    /// Goes up when the way «Play» runs for a title changes, so the buttons that name it redraw.
    private(set) var defaultsRevision = 0

    @ObservationIgnored private var defaults = WayDefaults()
    @ObservationIgnored private var defaultsScope = ""
    @ObservationIgnored private var catalog: AddonCatalog?
    @ObservationIgnored private weak var catalogClient: APIClient?
    @ObservationIgnored private var lastLoad: Date?

    /// A refresh asked for sooner than this after the last load does nothing.
    private static let refreshGap: TimeInterval = 30

    /// The ways offered for `target`, in order.
    func ways(for target: WayTarget, role: WayRole? = nil) -> [AddonWay] {
        snapshot.ways(for: target, role: role)
    }

    /// The ways that watch `target`, as «Play» and its menu show them: the way remembered for the
    /// title (else the first) is the default. nil when no way watches it.
    func menu(for target: WayTarget) -> WayMenu? {
        _ = defaultsRevision
        return defaults.menu(for: snapshot.ways(for: target, role: .watch), target: target)
    }

    /// `way` is what «Play» runs for the title of `target` from now on.
    func remember(_ way: AddonWay, for target: WayTarget) {
        defaults.remember(way.id, for: target)
        defaultsRevision += 1
    }

    /// `way`'s run for `target` itself is under way: its button shows the spinner, no other does.
    func isRunning(_ way: AddonWay, for target: WayTarget) -> Bool {
        runs.isRunning(way.id, for: target)
    }

    /// Some way's run for `target` itself is under way (an episode's card shows it).
    func isRunning(for target: WayTarget) -> Bool {
        runs.isRunning(for: target)
    }

    /// Finds what the addons offer (from the session's cache when it has it). `refresh` looks
    /// again: Home's counterpart of pull-to-refresh, which tvOS has no gesture for.
    func load(using appState: AppState, refresh: Bool = false) async {
        if let user = appState.currentUser, defaultsScope != String(user.id) {
            defaultsScope = String(user.id)
            defaults = WayDefaults(scope: defaultsScope)
            defaultsRevision += 1
        }
        guard let client = appState.client, let user = appState.currentUser, !user.isKid else {
            catalog = nil
            catalogClient = nil
            if !snapshot.isEmpty { snapshot = .empty }
            return
        }
        if catalog == nil || catalogClient !== client {
            catalog = AddonCatalog(client: client)
            catalogClient = client
            snapshot = .empty
            lastLoad = Date()
        } else if refresh {
            // A look that began a moment ago (the shell's own, at launch) is as good.
            if let lastLoad, Date().timeIntervalSince(lastLoad) < Self.refreshGap { return }
            lastLoad = Date()
            await catalog?.invalidate()
        }
        guard let catalog else { return }
        let found = await catalog.snapshot()
        guard catalogClient === client, !Task.isCancelled else { return }
        if found != snapshot { snapshot = found }
    }

    // MARK: Calling a way

    /// A way's button was pressed. A way that watches runs at once with the remembered or best
    /// choice (and opens the chooser only if the addon has none); one that keeps a copy, or one
    /// asked to `choose`, opens the chooser. A second press while a run is under way does nothing.
    func start(_ launch: WayLaunch, choose: Bool, appState: AppState, playback: PlaybackCoordinator) {
        if choose || launch.way.role == .keep {
            sheet = launch
            return
        }
        let key = WayRunKey(wayId: launch.way.id, target: launch.target)
        guard runs.begin(key) else { return }
        Task {
            defer { runs.end(key) }
            do {
                let (result, request) = try await perform(launch, ref: nil, quick: true, appState: appState)
                finish(result, request: request, launch: launch, appState: appState, playback: playback)
            } catch {
                report(error, appState: appState)
            }
        }
    }

    /// `POST x/app/run` for `launch` (the choice `ref` made in the chooser, or the quick run).
    /// `startSec`: where a stream starts (the chooser opened over a playing stream continues from
    /// there); left out, the addon starts where the person left off.
    func perform(
        _ launch: WayLaunch, ref: String?, quick: Bool, refresh: Bool = false, startSec: Double? = nil, appState: AppState
    ) async throws -> (WayRunResult, WayRunRequest) {
        guard let client = appState.client else { throw CancellationError() }
        let request = WayRunRequest(
            way: launch.way.way.id, target: launch.target, ref: ref, startSec: startSec,
            maxHeight: PlayerDevice.maxHeight, quick: quick, refresh: refresh
        )
        return (try await client.wayRun(addon: launch.way.addonId, request), request)
    }

    /// What a run's answer does: plays the stream, says what was done, or (for a quick run with no
    /// remembered choice) opens the chooser.
    func finish(_ result: WayRunResult, request: WayRunRequest, launch: WayLaunch, appState: AppState, playback: PlaybackCoordinator) {
        switch result {
        case .input(let id):
            playback.playWay(launch, source: .input(id), run: request)
        case .play(let play):
            playback.playWay(launch, source: .stream(play), run: request)
        case .done(let text):
            if !text.isEmpty { appState.showNotice(text) }
            changed()
        case .pick:
            if request.quick == true { sheet = launch }
        }
    }

    /// Something a way started or stopped: pages ask for the states again.
    func changed() {
        revision += 1
    }

    /// Shows a failed call's own message (the server's words, as it sent them).
    func report(_ error: Error, appState: AppState) {
        guard !(error is CancellationError), let message = appState.message(for: error) else { return }
        appState.showNotice(message)
    }
}

/// The state of what the ways of a page started (a copy being made), polled while any is active.
@MainActor
@Observable
final class WayStateModel {
    /// By `AddonWay.id`.
    private(set) var states: [String: WayState] = [:]

    /// Asks for the states of the keep ways among `ways` once, and again every
    /// `WayStatePolling.interval` seconds while any is active. Cancelling the task ends it.
    func poll(target: WayTarget, ways: [AddonWay], using appState: AppState) async {
        let keep = ways.filter { $0.role == .keep }
        guard !keep.isEmpty, let client = appState.client else {
            if !states.isEmpty { states = [:] }
            return
        }
        let addons = Array(Set(keep.map(\.addonId))).sorted()
        while !Task.isCancelled {
            var fresh: [String: WayState] = [:]
            await withTaskGroup(of: (String, [String: WayState]?).self) { group in
                for addon in addons {
                    group.addTask { (addon, try? await client.wayStates(addon: addon, target: target)) }
                }
                for await (addon, answer) in group {
                    for way in keep where way.addonId == addon {
                        // An addon that did not answer keeps what it showed.
                        if let state = answer?[way.way.id] ?? (answer == nil ? states[way.id] : nil) {
                            fresh[way.id] = state
                        }
                    }
                }
            }
            guard !Task.isCancelled else { return }
            if states != fresh { states = fresh }
            guard WayStatePolling.shouldContinue(fresh) else { return }
            try? await Task.sleep(for: .seconds(WayStatePolling.interval))
        }
    }

    /// «Cancel» on an active way: `POST x/app/cancel`, then the pages ask again.
    func cancel(_ way: AddonWay, target: WayTarget, appState: AppState, addons: AddonWays) async {
        guard let client = appState.client else { return }
        do {
            let notice = try await client.wayCancel(addon: way.addonId, WayCancelRequest(way: way.way.id, target: target))
            if let notice, !notice.isEmpty { appState.showNotice(notice) }
        } catch {
            addons.report(error, appState: appState)
        }
        addons.changed()
    }
}
