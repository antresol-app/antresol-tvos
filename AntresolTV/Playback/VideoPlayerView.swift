import AVKit
import AntresolKit
import SwiftUI

/// Full-screen player presented by the shell for `PlaybackCoordinator.presented`.
struct VideoPlayerView: View {
    let request: PlaybackCoordinator.Request

    @Environment(AppState.self) private var appState
    @Environment(PlaybackCoordinator.self) private var coordinator
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var model: VideoPlayerModel

    init(request: PlaybackCoordinator.Request) {
        self.request = request
        _model = State(initialValue: VideoPlayerModel(request: request))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            switch model.state {
            case .preparing:
                PreparingView(card: model.card)
            case .resumePrompt(let position, let family):
                ResumePromptView(
                    card: model.card, positionSec: position, durationSec: model.durationSec, family: family,
                    chooseOwn: { resume in Task { await model.choose(resume: resume) } },
                    chooseFamily: { member in Task { await model.chooseFamily(member) } }
                )
            case .playing:
                PlayerViewController(model: model, subtitle: model.subtitleText, subtitleRaised: model.isPaused, menus: model.menus, skip: model.skipOverlay)
                    .ignoresSafeArea()
                    .overlay {
                        if model.isSwitching {
                            ProgressView()
                                .padding(36)
                                .glassSurface(in: Circle(), highlighted: false, interactive: false)
                        }
                    }
                    .overlay(alignment: .top) {
                        VStack(spacing: 16) {
                            if let notice = model.notice {
                                NoticeBanner(message: notice, systemImage: "exclamationmark.circle")
                                    .transition(.move(edge: .top).combined(with: .opacity))
                            }
                            if let kind = model.skipOverlay.note {
                                NoticeBanner(message: SkipLabels.skipped(kind), systemImage: "forward.end")
                                    .accessibilityIdentifier("player.skip.note")
                                    .transition(.move(edge: .top).combined(with: .opacity))
                            }
                        }
                        .padding(.top, 60)
                    }
                    .animation(Theme.Motion.easeOut, value: model.notice)
                    .animation(Theme.Motion.easeOut, value: model.skipOverlay.note)
                    #if DEBUG
                    .background { PlayerClockProbe(model: model) }
                    #endif
            case .failed(let message):
                PlaybackErrorView(card: model.card, message: message) {
                    Task { await model.retry() }
                } close: {
                    dismiss()
                }
            }
        }
        .task { await model.start(appState: appState, coordinator: coordinator) }
        .onChange(of: model.didFinish) { _, finished in
            if finished { dismiss() }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background: Task { await model.suspend() }
            case .active: Task { await model.resumeFromBackground() }
            default: model.flushProgress()
            }
        }
        .onDisappear {
            Task {
                await model.stop()
                coordinator.playerDidClose(request)
            }
        }
    }
}

#if DEBUG
/// The player's file position in whole seconds and the skip pill on screen as
/// accessibility values, for the UI tests (the system transport bar and contextual actions
/// are not theirs to read). Debug builds only.
private struct PlayerClockProbe: View {
    let model: VideoPlayerModel

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { _ in
            Color.clear
                .frame(width: 2, height: 2)
                .accessibilityElement()
                .accessibilityIdentifier("player.position")
                .accessibilityValue(Text(verbatim: model.filePositionForTests.map { String(Int($0)) } ?? ""))
                .overlay {
                    // The skip pill on screen (the player's contextual actions are not in
                    // the app's accessibility tree): "intro", "recap", "credits", "next", "undo" or "".
                    Color.clear
                        .frame(width: 2, height: 2)
                        .accessibilityElement()
                        .accessibilityIdentifier("player.skip")
                        .accessibilityValue(Text(verbatim: skipValue))
                }
        }
        .allowsHitTesting(false)
    }

    private var skipValue: String {
        switch model.skipOverlay.button {
        case .skip(let kind)?: return kind
        case .next?: return "next"
        case .undo?: return "undo"
        case nil: return ""
        }
    }
}
#endif

/// `AVPlayerViewController` with the system transport bar and info panel, plus the
/// app's Audio / Subtitles / Quality / «Пропускать сам» menus, the subtitle overlay, Up Next
/// and the skip pills (the system's contextual actions, bottom right: focused while the
/// transport bar is hidden, so Select presses them).
private struct PlayerViewController: UIViewControllerRepresentable {
    let model: VideoPlayerModel
    let subtitle: String?
    let subtitleRaised: Bool
    let menus: PlayerMenuState
    let skip: SkipOverlay

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model)
    }

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = model.player
        controller.delegate = context.coordinator
        controller.contentProposalViewController = UpNextProposalViewController(model: model)
        let overlay = SubtitleOverlayView()
        if let container = controller.contentOverlayView {
            overlay.frame = container.bounds
            overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            container.addSubview(overlay)
        }
        context.coordinator.subtitleView = overlay
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        if controller.player !== model.player {
            controller.player = model.player
        }
        context.coordinator.subtitleView?.text = subtitle
        context.coordinator.subtitleView?.raised = subtitleRaised
        if context.coordinator.menus != menus || context.coordinator.skip.barButton != skip.barButton {
            context.coordinator.menus = menus
            controller.transportBarCustomMenuItems = Self.actions(for: skip.barButton, model: model)
                + PlayerMenus.make(menus, model: model)
        }
        if context.coordinator.skip.button != skip.button {
            controller.contextualActions = Self.actions(for: skip.button, model: model)
        }
        context.coordinator.skip = skip
    }

    /// The skip pill: a contextual action over the video, or the first button of the
    /// transport bar while that is up.
    private static func actions(for button: SkipOverlay.Button?, model: VideoPlayerModel) -> [UIAction] {
        switch button {
        case .skip(let kind)?:
            return [UIAction(title: SkipLabels.skip(kind), image: UIImage(systemName: "forward.end.fill")) { [weak model] _ in
                MainActor.assumeIsolated { model?.pressSkip() }
            }]
        case .next?:
            // The Up Next panel's pair, for credits entered without it: «Watch Credits» also
            // stops the countdown.
            return [
                UIAction(title: String(localized: "Next Episode", bundle: .localized), image: UIImage(systemName: "play.fill")) { [weak model] _ in
                    MainActor.assumeIsolated { model?.pressSkip() }
                },
                UIAction(title: String(localized: "Watch Credits", bundle: .localized)) { [weak model] _ in
                    MainActor.assumeIsolated { model?.declineUpNext() }
                },
            ]
        case .undo?:
            return [UIAction(title: String(localized: "Go Back", bundle: .localized), image: UIImage(systemName: "arrow.uturn.backward")) { [weak model] _ in
                MainActor.assumeIsolated { model?.undoSkip() }
            }]
        case nil:
            return []
        }
    }

    /// Delegate callbacks arrive on the main thread.
    final class Coordinator: NSObject, AVPlayerViewControllerDelegate {
        let model: VideoPlayerModel
        var subtitleView: SubtitleOverlayView?
        var menus: PlayerMenuState?
        var skip = SkipOverlay()

        init(model: VideoPlayerModel) {
            self.model = model
        }

        func playerViewController(_ playerViewController: AVPlayerViewController, shouldPresent proposal: AVContentProposal) -> Bool {
            true
        }

        func playerViewController(_ playerViewController: AVPlayerViewController, didAccept proposal: AVContentProposal) {
            MainActor.assumeIsolated { model.acceptUpNext() }
        }

        func playerViewController(_ playerViewController: AVPlayerViewController, didReject proposal: AVContentProposal) {
            MainActor.assumeIsolated { model.declineUpNext() }
        }

        func playerViewController(
            _ playerViewController: AVPlayerViewController,
            willTransitionToVisibilityOfTransportBar visible: Bool,
            with coordinator: AVPlayerViewControllerAnimationCoordinator
        ) {
            MainActor.assumeIsolated { model.setControlsVisible(visible) }
        }

        func playerViewController(
            _ playerViewController: AVPlayerViewController,
            timeToSeekAfterUserNavigatedFrom oldTime: CMTime,
            to targetTime: CMTime
        ) -> CMTime {
            MainActor.assumeIsolated { model.resolveUserSeek(from: oldTime, to: targetTime) }
        }
    }
}

/// Artwork-tinted background with a spinner while the stream is being prepared.
struct PreparingView: View {
    let card: Card
    /// What is being prepared, when it is not the card itself (a trailer's name).
    var title: String?

    var body: some View {
        ZStack {
            HeroBackground(card: card)
                .ignoresSafeArea()
                .opacity(0.6)
            VStack(spacing: 28) {
                ProgressView()
                Text(verbatim: title ?? card.title)
                    .font(Theme.Typography.headline)
                    .foregroundStyle(Theme.Colors.label2)
            }
        }
    }
}

/// "Resume from 12:34" or "Start Over", over the item's artwork; with the places of other
/// profiles (`family`) one row each between them: «Дарья · 1:12:40» (the avatar, the name, the
/// place, and the episode when it is another one). Without a place of its own the first row is
/// «Play» and there is no «Start Over».
private struct ResumePromptView: View {
    let card: Card
    let positionSec: Double
    let durationSec: Double
    let family: [FamilyMember]
    let chooseOwn: (Bool) -> Void
    let chooseFamily: (FamilyMember) -> Void

    private enum Choice: Hashable {
        case own
        case startOver
        case member(Int)
    }

    @FocusState private var focused: Choice?

    private var hasOwnPlace: Bool { FamilyResume.hasOwnPlace(positionSec) }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            HeroBackground(card: card)
                .ignoresSafeArea()
            VStack(alignment: .leading, spacing: 18) {
                Text(verbatim: (card.subtitle.isEmpty ? card.kind.displayName : card.subtitle).uppercased())
                    .font(Theme.Typography.eyebrow)
                    .tracking(2)
                    .foregroundStyle(Theme.Colors.label2)
                Text(verbatim: card.title)
                    .font(Theme.Typography.heroTitle)
                    .foregroundStyle(Theme.Colors.label)
                    .lineLimit(2)
                    .minimumScaleFactor(0.6)
                if hasOwnPlace, durationSec > 0 {
                    HStack(spacing: 20) {
                        ProgressBar(value: min(1, positionSec / durationSec), height: 8)
                            .frame(width: 420)
                        Text(verbatim: PlaybackTime.remaining(durationSec - positionSec))
                            .font(Theme.Typography.meta)
                            .foregroundStyle(Theme.Colors.label2)
                    }
                }
                GlassGroup(spacing: 28) {
                    if family.isEmpty {
                        HStack(spacing: 28) { choices }
                    } else {
                        VStack(alignment: .leading, spacing: 22) { choices }
                            .frame(maxWidth: 760, alignment: .leading)
                    }
                }
                .padding(.top, 20)
                .focusSection()
            }
            .padding(.horizontal, Theme.Layout.margin)
            .padding(.bottom, 110)
        }
        .defaultFocus($focused, .own)
    }

    @ViewBuilder
    private var choices: some View {
        Button {
            chooseOwn(true)
        } label: {
            Label {
                if hasOwnPlace {
                    Text("Resume from \(PlaybackTime.clock(positionSec))")
                } else {
                    Text("Play")
                }
            } icon: {
                Image(systemName: "play.fill")
            }
            .rowWidth(!family.isEmpty)
        }
        // Two buttons: the first is the lit one, as it always was. A list: only the focused row is lit,
        // so it is clear which one has the focus.
        .buttonStyle(PillButtonStyle(kind: family.isEmpty ? .primary : .glass))
        .focused($focused, equals: .own)
        .accessibilityIdentifier("resume.own")
        ForEach(family) { member in
            Button {
                chooseFamily(member)
            } label: {
                Label {
                    Text(verbatim: FamilyText.promptRow(member, playing: card.id))
                } icon: {
                    AvatarView(name: member.name, preset: member.avatarPreset, photo: member.photo, size: 48)
                }
                .rowWidth(true)
            }
            .buttonStyle(PillButtonStyle(kind: .glass))
            .focused($focused, equals: .member(member.userId))
            .accessibilityHint(Text("Continue from Their Place"))
            .accessibilityIdentifier("resume.family.\(member.userId)")
        }
        if hasOwnPlace {
            Button {
                chooseOwn(false)
            } label: {
                Label("Start Over", systemImage: "arrow.counterclockwise")
                    .rowWidth(!family.isEmpty)
            }
            .buttonStyle(PillButtonStyle(kind: .glass))
            .focused($focused, equals: .startOver)
            .accessibilityIdentifier("resume.startOver")
        }
    }
}

private extension View {
    /// The rows of a list of choices are as wide as each other, their words at the leading edge.
    @ViewBuilder
    func rowWidth(_ full: Bool) -> some View {
        if full {
            frame(maxWidth: .infinity, alignment: .leading)
        } else {
            self
        }
    }
}

/// Why playback could not start or stopped, with Try Again and Close.
struct PlaybackErrorView: View {
    let card: Card
    /// What could not play, when it is not the card itself (a trailer's name).
    var title: String?
    let message: String
    let retry: () -> Void
    let close: () -> Void

    var body: some View {
        ZStack {
            HeroBackground(card: card)
                .ignoresSafeArea()
                .opacity(0.35)
            VStack(spacing: 30) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 80))
                    .foregroundStyle(Theme.Colors.label3)
                Text("Can’t Play “\(title ?? card.title)”")
                    .font(Theme.Typography.sectionTitle)
                    .foregroundStyle(Theme.Colors.label)
                    .multilineTextAlignment(.center)
                Text(verbatim: message)
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Colors.label2)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 1100)
                HStack(spacing: 28) {
                    Button(action: retry) {
                        Label("Try Again", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(PillButtonStyle(kind: .primary))
                    Button(action: close) {
                        Text("Close")
                    }
                    .buttonStyle(PillButtonStyle(kind: .glass))
                }
                .padding(.top, 10)
            }
            .padding(Theme.Layout.margin)
        }
    }
}

/// The skip pills' words.
enum SkipLabels {
    /// «Пропустить пересказ / вступление / титры».
    static func skip(_ kind: String) -> String {
        switch kind {
        case SkipSegments.recap: return String(localized: "Skip Recap", bundle: .localized)
        case SkipSegments.intro: return String(localized: "Skip Intro", bundle: .localized)
        default: return String(localized: "Skip Credits", bundle: .localized)
        }
    }

    /// «Пересказ пропущен» / «Вступление пропущено».
    static func skipped(_ kind: String) -> String {
        kind == SkipSegments.recap
            ? String(localized: "Recap skipped", bundle: .localized)
            : String(localized: "Intro skipped", bundle: .localized)
    }
}

/// Clock and "time left" strings for the player.
enum PlaybackTime {
    /// "1:02:03" or "12:34".
    static func clock(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%d:%02d", minutes, secs)
    }

    /// "42 min left", or "1 min left" for the last minute.
    static func remaining(_ seconds: Double) -> String {
        let minutes = max(1, Int((seconds / 60).rounded(.up)))
        return String(localized: "\(minutes) min left", bundle: .localized)
    }
}
