import AntresolKit
import SwiftUI

extension WayIcon {
    /// The app's own symbol for the glyph a way asks for.
    var symbolName: String {
        switch self {
        case .play: return "play.fill"
        case .download: return "arrow.down.circle"
        case .globe: return "globe"
        case .list: return "list.bullet"
        }
    }
}

/// What a page's state polling is for: it starts again when the title, what the addons offer or a way's
/// doing changes.
struct WayPollKey: Hashable {
    let target: WayTarget?
    let snapshot: AddonCatalogSnapshot
    let revision: Int
}

/// The ways of a page that watch, in its action row. With a Play button of its own they come after
/// it: one way as its own button, several behind «Watch». Without one (a title the library lacks)
/// the first way is the first, primary button.
struct WayWatchButtons: View {
    let target: WayTarget
    /// The title's card, for the chooser and the player.
    let card: Card
    /// The page has its own Play button.
    let hasPlay: Bool

    @Environment(AppState.self) private var appState
    @Environment(AddonWays.self) private var addons
    @Environment(PlaybackCoordinator.self) private var playback
    @State private var choosing = false

    var body: some View {
        let ways = addons.ways(for: target, role: .watch)
        if hasPlay, ways.count > 1 {
            Button {
                choosing = true
            } label: {
                Label("Watch", systemImage: "play.rectangle.on.rectangle")
            }
            .buttonStyle(PillButtonStyle(kind: .glass))
            .confirmationDialog("Watch", isPresented: $choosing, titleVisibility: .visible) {
                ForEach(ways) { way in
                    Button(way.label) { start(way, choose: false) }
                }
                // Each way again, to pick the source by hand instead of the remembered one.
                ForEach(ways) { way in
                    Button(way.label + "…") { start(way, choose: true) }
                }
                Button("Cancel", role: .cancel) {}
            }
        } else {
            ForEach(Array(ways.enumerated()), id: \.element.id) { index, way in
                WayButton(way: way, target: target, card: card, kind: !hasPlay && index == 0 ? .primary : .glass)
            }
        }
    }

    private func start(_ way: AddonWay, choose: Bool) {
        addons.start(WayLaunch(way: way, target: target, card: card), choose: choose, appState: appState, playback: playback)
    }
}

/// One way that watches: a pill with the server's label. Select runs it at once with the remembered
/// or best choice; a long press offers the chooser.
struct WayButton: View {
    let way: AddonWay
    let target: WayTarget
    let card: Card
    var kind: PillButtonStyle.Kind = .glass

    @Environment(AppState.self) private var appState
    @Environment(AddonWays.self) private var addons
    @Environment(PlaybackCoordinator.self) private var playback

    var body: some View {
        let running = addons.running.contains(way.id)
        Button {
            start(choose: false)
        } label: {
            Label {
                Text(verbatim: way.label)
            } icon: {
                if running {
                    ProgressView()
                } else {
                    Image(systemName: way.icon.symbolName)
                }
            }
        }
        .buttonStyle(PillButtonStyle(kind: kind))
        .disabled(running)
        .contextMenu {
            Button {
                start(choose: true)
            } label: {
                Label(way.label + "…", systemImage: WayIcon.list.symbolName)
            }
        }
    }

    private func start(choose: Bool) {
        addons.start(WayLaunch(way: way, target: target, card: card), choose: choose, appState: appState, playback: playback)
    }
}

/// The ways that keep a copy on the server: a round button each, with a ring while the copy is
/// being made. Select opens the chooser; a long press says how far it is and cancels it.
struct WayKeepButtons: View {
    let target: WayTarget
    let card: Card
    let states: WayStateModel

    @Environment(AddonWays.self) private var addons

    var body: some View {
        ForEach(addons.ways(for: target, role: .keep)) { way in
            KeepWayButton(way: way, target: target, card: card, states: states)
        }
    }
}

private struct KeepWayButton: View {
    let way: AddonWay
    let target: WayTarget
    let card: Card
    let states: WayStateModel

    @Environment(AppState.self) private var appState
    @Environment(AddonWays.self) private var addons
    @Environment(PlaybackCoordinator.self) private var playback

    var body: some View {
        let state = states.states[way.id]
        Button {
            addons.start(WayLaunch(way: way, target: target, card: card), choose: true, appState: appState, playback: playback)
        } label: {
            ZStack {
                WayRing(state: state)
                    .frame(width: 80, height: 80)
                Image(systemName: way.icon.symbolName)
            }
        }
        .buttonStyle(CircleButtonStyle(isActive: state?.active == true))
        .accessibilityLabel(Text(verbatim: way.label))
        .accessibilityValue(Text(verbatim: state?.active == true ? (state?.text ?? "") : ""))
        .contextMenu {
            if let state, state.active {
                if let text = state.text {
                    Button {} label: { Text(verbatim: text) }
                        .disabled(true)
                }
                if state.cancel {
                    Button(role: .destructive) {
                        Task { await states.cancel(way, target: target, appState: appState, addons: addons) }
                    } label: {
                        Label("Cancel Task", systemImage: "xmark.circle")
                    }
                }
            }
        }
    }
}

/// The ring round a keep button while its way is active: filled to `fraction`, or turning when
/// the way does not know how far it is.
private struct WayRing: View {
    let state: WayState?

    var body: some View {
        if let state, state.active {
            ZStack {
                Circle().stroke(Color.white.opacity(0.2), lineWidth: 6)
                if let fraction = state.fraction {
                    Circle()
                        .trim(from: 0, to: max(fraction, 0.02))
                        .stroke(Theme.Colors.accent, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                } else {
                    TimelineView(.animation) { context in
                        Circle()
                            .trim(from: 0, to: 0.25)
                            .stroke(Theme.Colors.accent, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                            .rotationEffect(.degrees(context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.2) / 1.2 * 360))
                    }
                }
            }
            .accessibilityHidden(true)
        }
    }
}

/// The ways offered for one episode, as entries of its long-press menu: each runs at once with
/// the remembered or best choice; a way that watches also has its chooser.
struct EpisodeWayMenu: View {
    let target: WayTarget
    let card: Card

    @Environment(AppState.self) private var appState
    @Environment(AddonWays.self) private var addons
    @Environment(PlaybackCoordinator.self) private var playback

    var body: some View {
        ForEach(addons.ways(for: target)) { way in
            Button {
                start(way, choose: false)
            } label: {
                Label(way.label, systemImage: way.icon.symbolName)
            }
            if way.role == .watch {
                Button {
                    start(way, choose: true)
                } label: {
                    Label(way.label + "…", systemImage: WayIcon.list.symbolName)
                }
            }
        }
    }

    private func start(_ way: AddonWay, choose: Bool) {
        addons.start(WayLaunch(way: way, target: target, card: card), choose: choose, appState: appState, playback: playback)
    }
}
