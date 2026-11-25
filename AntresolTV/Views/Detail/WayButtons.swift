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

/// The words of the menu's rows: the way's own label, and the app's line for how its glyph plays.
extension WayHint {
    var text: String {
        switch self {
        case .startsRightAway: return String(localized: "Starts right away", bundle: .localized)
        case .startsAfterWait: return String(localized: "Starts after a short wait", bundle: .localized)
        }
    }
}

extension WayMenuRow {
    /// «Online — starts right away»: the way's label, then the hint when its glyph gives one.
    var title: String {
        guard let hint else { return way.label }
        return way.label + " — " + hint.text
    }
}

/// The ways of a page that watch, in its action row: one pill that runs the way chosen for the title
/// (else the first) at once, and a chevron button beside it that opens the menu of the ways. A page
/// without a Play button of its own (a title the library lacks) shows «Play» as that pill; with one, the
/// pill carries the way's own label, after the page's Play.
struct WayWatchButtons: View {
    let target: WayTarget
    /// The title's card, for the chooser and the player.
    let card: Card
    /// The page has its own Play button.
    let hasPlay: Bool

    @Environment(AddonWays.self) private var addons

    var body: some View {
        if let menu = addons.menu(for: target) {
            WayPlayButtons(menu: menu, target: target, card: card, isPlay: !hasPlay)
        }
    }
}

/// The pill and its menu button. They sit close, as the two parts of one control.
private struct WayPlayButtons: View {
    let menu: WayMenu
    let target: WayTarget
    let card: Card
    /// The pill is the page's Play («Play», the primary pill); else the way's own label on a glass pill.
    let isPlay: Bool

    @Environment(AppState.self) private var appState
    @Environment(AddonWays.self) private var addons
    @Environment(PlaybackCoordinator.self) private var playback

    var body: some View {
        let way = menu.defaultWay
        let kind: PillButtonStyle.Kind = isPlay ? .primary : .glass
        HStack(spacing: 10) {
            Button {
                addons.start(WayLaunch(way: way, target: target, card: card), choose: false, appState: appState, playback: playback)
            } label: {
                Label {
                    if isPlay {
                        Text("Play")
                    } else {
                        Text(verbatim: way.label)
                    }
                } icon: {
                    if addons.isRunning(way, for: target) {
                        ProgressView()
                    } else {
                        Image(systemName: isPlay ? "play.fill" : way.icon.symbolName)
                    }
                }
            }
            .buttonStyle(PillButtonStyle(kind: kind, segment: .leading))
            // Not `.disabled` while it runs: a button that goes disabled and enabled again under the focus
            // engine stops reporting its focus. `AddonWays.start` ignores a second press meanwhile.
            .accessibilityIdentifier("way-play")

            Menu {
                WayMenuItems(menu: menu, target: target, card: card)
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 30, weight: .semibold))
            }
            .buttonStyle(PillButtonStyle(kind: kind, segment: .trailing))
            .accessibilityLabel(Text("Ways to Watch"))
            .accessibilityIdentifier("way-menu")
        }
        // The pills keep their own width: a stack in the action row's scroll view would squeeze the label.
        .fixedSize(horizontal: true, vertical: false)
    }
}

/// The rows of a way menu: one per way that watches (the one «Play» runs ticked; choosing another makes
/// it the title's way and runs it), then «Audio & quality…», the step-by-step choice of the ticked way.
/// An episode's long-press menu starts with «Play» too.
struct WayMenuItems: View {
    let menu: WayMenu
    let target: WayTarget
    let card: Card
    var includesPlay = false

    @Environment(AppState.self) private var appState
    @Environment(AddonWays.self) private var addons
    @Environment(PlaybackCoordinator.self) private var playback

    var body: some View {
        if includesPlay {
            Button {
                start(menu.defaultWay, choose: false)
            } label: {
                Label("Play", systemImage: "play.fill")
            }
            Divider()
        }
        ForEach(menu.rows) { row in
            Toggle(isOn: Binding(get: { row.isDefault }, set: { _ in pick(row.way) })) {
                Text(verbatim: row.title)
            }
        }
        Divider()
        Button {
            start(menu.defaultWay, choose: true)
        } label: {
            Label("Audio & quality…", systemImage: WayIcon.list.symbolName)
        }
    }

    /// Makes `way` the title's way and runs it.
    private func pick(_ way: AddonWay) {
        addons.remember(way, for: target)
        start(way, choose: false)
    }

    private func start(_ way: AddonWay, choose: Bool) {
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

/// The ways offered for one episode, as its long-press menu: «Play» (the way chosen for the show), the
/// same rows as the menu beside a page's Play, and the ways that keep a copy.
struct EpisodeWayMenu: View {
    let target: WayTarget
    let card: Card

    @Environment(AppState.self) private var appState
    @Environment(AddonWays.self) private var addons
    @Environment(PlaybackCoordinator.self) private var playback

    var body: some View {
        if let menu = addons.menu(for: target) {
            WayMenuItems(menu: menu, target: target, card: card, includesPlay: true)
        }
        ForEach(addons.ways(for: target, role: .keep)) { way in
            Button {
                addons.start(WayLaunch(way: way, target: target, card: card), choose: true, appState: appState, playback: playback)
            } label: {
                Label(way.label, systemImage: way.icon.symbolName)
            }
        }
    }
}

extension View {
    /// A spinner over an episode's card while a run for that very episode is under way.
    func wayBusy(_ isBusy: Bool) -> some View {
        overlay {
            if isBusy {
                ProgressView()
                    .padding(32)
                    .glassSurface(in: Circle(), highlighted: false, interactive: false)
            }
        }
    }
}
