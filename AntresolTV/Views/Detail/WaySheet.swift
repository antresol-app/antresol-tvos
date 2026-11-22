import AntresolKit
import Observation
import SwiftUI

/// The chooser a way opens: the addon's steps one after another (`x/app/step`), each a list of
/// rows. A row that is not final opens the next step; a final one runs the way. Menu goes back a
/// step, and closes the chooser from the first.
@MainActor
@Observable
final class WaySheetModel {
    enum Phase {
        /// A step is being asked for (a search for sources can take most of half a minute).
        case loading
        case step(WayStep)
        case failed(String)
    }

    let launch: WayLaunch
    /// The stream the chooser opened over («Audio & source…» in the player): what is chosen replaces
    /// it, from where it is. nil: the chooser of a page.
    let player: WayPlayerModel?
    private(set) var phase: Phase = .loading
    /// A final row was chosen and the way is running.
    private(set) var isRunning = false
    /// The last run's error, shown under the list.
    private(set) var runError: String?
    /// The steps shown so far; the last is the current one.
    private(set) var steps: [WayStep] = []

    /// The `ref` of the step being asked for (none for the first), for Try Again.
    @ObservationIgnored private var asking: String??
    @ObservationIgnored private var task: Task<Void, Never>?

    init(launch: WayLaunch, player: WayPlayerModel? = nil) {
        self.launch = launch
        self.player = player
    }

    /// The row of the current step the person chose last: it starts focused.
    var currentRef: String? {
        if case .step(let step) = phase { return step.rows.first(where: \.current)?.ref ?? step.rows.first?.ref }
        return nil
    }

    /// The first step.
    func begin(appState: AppState, addons: AddonWays) {
        ask(ref: nil, appState: appState, addons: addons)
    }

    /// Asks again after a failure.
    func retry(appState: AppState, addons: AddonWays) {
        guard let asking else { return }
        ask(ref: asking, appState: appState, addons: addons)
    }

    /// A row was chosen.
    func choose(_ row: WayRow, appState: AppState, addons: AddonWays, playback: PlaybackCoordinator) {
        guard !isRunning else { return }
        runError = nil
        if row.isFinal {
            run(row, appState: appState, addons: addons, playback: playback)
        } else {
            ask(ref: row.ref, appState: appState, addons: addons)
        }
    }

    /// Menu: back to the previous step. False when there is none (the chooser closes).
    func back() -> Bool {
        guard !isRunning else { return true }
        // A next step being asked for is given up; the one before it shows again.
        if case .step = phase {} else if !steps.isEmpty {
            task?.cancel()
            phase = .step(steps[steps.count - 1])
            return true
        }
        guard steps.count > 1 else { return false }
        steps.removeLast()
        runError = nil
        phase = .step(steps[steps.count - 1])
        return true
    }

    /// The chooser closed: whatever is still being asked for is given up.
    func cancel() {
        task?.cancel()
    }

    private func ask(ref: String?, appState: AppState, addons: AddonWays) {
        task?.cancel()
        asking = .some(ref)
        phase = .loading
        task = Task { [launch] in
            guard let client = appState.client else { return }
            do {
                let step = try await client.wayStep(addon: launch.way.addonId, WayStepRequest(way: launch.way.way.id, target: launch.target, ref: ref))
                guard !Task.isCancelled else { return }
                self.steps.append(step)
                self.phase = .step(step)
            } catch {
                guard !Task.isCancelled else { return }
                if let status = (error as? APIError)?.statusCode, status == 404 {
                    // The way is gone from the addon: look at what it offers again.
                    Task { await addons.load(using: appState, refresh: true) }
                }
                if let message = appState.message(for: error) {
                    self.phase = .failed(message)
                }
            }
        }
    }

    private func run(_ row: WayRow, appState: AppState, addons: AddonWays, playback: PlaybackCoordinator) {
        isRunning = true
        task?.cancel()
        task = Task { [launch, player] in
            do {
                // Over a stream, the run starts where that stream is.
                let (result, request) = try await addons.perform(
                    launch, ref: row.ref, quick: false, startSec: player?.position, appState: appState
                )
                guard !Task.isCancelled else { return }
                if let player {
                    // The old stream stays paused while the chooser goes, then the new one takes its place.
                    player.beginReplacing()
                    player.chooser = nil
                    try? await Task.sleep(for: .milliseconds(600))
                    player.apply(result, run: request, launch: launch, addons: addons)
                    return
                }
                // The chooser goes first: a player cannot come up over a sheet still on screen.
                addons.sheet = nil
                try? await Task.sleep(for: .milliseconds(600))
                addons.finish(result, request: request, launch: launch, appState: appState, playback: playback)
            } catch {
                guard !Task.isCancelled else { return }
                self.isRunning = false
                self.runError = appState.message(for: error)
                if (error as? APIError)?.statusCode == 404 {
                    Task { await addons.load(using: appState, refresh: true) }
                }
            }
        }
    }
}

/// The chooser's page: the step's title and note, then its rows (label, second line, badges, a
/// check on the last choice, a chevron where another step follows).
struct WaySheetView: View {
    let launch: WayLaunch
    /// The playing stream the chooser opened over, if any.
    var player: WayPlayerModel?

    @Environment(AppState.self) private var appState
    @Environment(AddonWays.self) private var addons
    @Environment(PlaybackCoordinator.self) private var playback
    @Environment(\.dismiss) private var dismiss
    @State private var model: WaySheetModel
    @FocusState private var focused: String?

    init(launch: WayLaunch, player: WayPlayerModel? = nil) {
        self.launch = launch
        self.player = player
        _model = State(initialValue: WaySheetModel(launch: launch, player: player))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            header
            content
        }
        .padding(.horizontal, Theme.Layout.margin)
        .padding(.vertical, 56)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.Colors.background.ignoresSafeArea())
        .task { model.begin(appState: appState, addons: addons) }
        .onExitCommand {
            if !model.back() { dismiss() }
        }
        .onDisappear { model.cancel() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(verbatim: launch.way.label)
                .font(Theme.Typography.eyebrow)
                .tracking(2)
                .textCase(.uppercase)
                .foregroundStyle(Theme.Colors.label2)
                .lineLimit(1)
            Text(verbatim: headline)
                .font(Theme.Typography.pageTitle)
                .foregroundStyle(Theme.Colors.label)
                .lineLimit(2)
                .minimumScaleFactor(0.6)
                .accessibilityAddTraits(.isHeader)
            if case .step(let step) = model.phase, let note = step.note {
                Text(verbatim: note)
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Colors.label2)
                    .lineLimit(3)
            }
        }
    }

    /// The step's own title, else the title the chooser is for.
    private var headline: String {
        if case .step(let step) = model.phase, !step.title.isEmpty { return step.title }
        return launch.card.title
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity, minHeight: 360)
        case .failed(let message):
            VStack(spacing: 28) {
                ErrorLine(message: message)
                Button {
                    model.retry(appState: appState, addons: addons)
                } label: {
                    Label("Try Again", systemImage: "arrow.clockwise")
                }
                .buttonStyle(PillButtonStyle(kind: .primary))
            }
            .frame(maxWidth: .infinity, minHeight: 360)
        case .step(let step):
            if step.rows.isEmpty {
                Text(verbatim: step.empty ?? String(localized: "Nothing Found", bundle: .localized))
                    .font(Theme.Typography.headline)
                    .foregroundStyle(Theme.Colors.label2)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, minHeight: 360)
            } else {
                rows(step)
            }
        }
    }

    private func rows(_ step: WayStep) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            ScrollView(.vertical, showsIndicators: false) {
                // A plain stack: a step has a few dozen rows at most, and the last choice must exist to take focus.
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(step.rows) { row in
                        Button {
                            model.choose(row, appState: appState, addons: addons, playback: playback)
                        } label: {
                            WayRowLabel(row: row)
                        }
                        .buttonStyle(ListRowButtonStyle())
                        .focused($focused, equals: row.ref)
                        .accessibilityAddTraits(row.current ? .isSelected : [])
                    }
                }
                .padding(.horizontal, Theme.Layout.listRowInset)
                .padding(.vertical, 12)
            }
            .scrollClipDisabled()
            .listRowOutdent()
            // A new step starts with its own focus: the last choice, else the first row.
            .id(step)
            .defaultFocus($focused, model.currentRef)
            .task(id: step) {
                await Task.yield()
                focused = model.currentRef
            }
            .disabled(model.isRunning)
            .overlay {
                if model.isRunning {
                    ProgressView()
                        .padding(36)
                        .glassSurface(in: Circle(), highlighted: false, interactive: false)
                }
            }
            if let error = model.runError {
                ErrorLine(message: error)
            }
        }
    }
}

/// One row of a step.
private struct WayRowLabel: View {
    let row: WayRow

    var body: some View {
        HStack(spacing: 24) {
            VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: row.label)
                    .font(Theme.Typography.headline)
                    .lineLimit(2)
                if let detail = row.detail {
                    Text(verbatim: detail)
                        .font(Theme.Typography.cardMeta)
                        .opacity(0.7)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 24)
            if !row.badges.isEmpty {
                BadgeRow(badges: row.badges)
            }
            if row.current {
                Image(systemName: "checkmark")
                    .font(Theme.Typography.headline)
            }
            if !row.isFinal {
                Image(systemName: "chevron.right")
                    .font(Theme.Typography.headline)
                    .opacity(0.6)
            }
        }
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// What the shell presents for the addons' ways: the chooser (a sheet), the player of a stream a way
/// started (full screen, in a host of its own: a second cover needs one) and the addons' discovery
/// when the shell comes up (nothing for a kid or a server without addons).
struct WayPresentations: ViewModifier {
    let addons: AddonWays
    let playback: PlaybackCoordinator
    let appState: AppState
    /// A way's stream is about to play: the music steps aside.
    let onPlay: () -> Void

    func body(content: Content) -> some View {
        content
            .sheet(item: Binding(get: { addons.sheet }, set: { addons.sheet = $0 })) { launch in
                WaySheetView(launch: launch)
                    .environment(appState)
                    .environment(addons)
                    .environment(playback)
            }
            .background {
                Color.clear
                    .fullScreenCover(item: Binding(get: { playback.presentedWay }, set: { playback.presentedWay = $0 })) { request in
                        WayPlayerView(request: request)
                            .environment(appState)
                            .environment(addons)
                            .environment(playback)
                    }
            }
            .onChange(of: playback.presentedWay) { _, request in
                if request != nil { onPlay() }
            }
            .task { await addons.load(using: appState) }
    }
}
