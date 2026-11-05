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
            case .resumePrompt(let position):
                ResumePromptView(card: model.card, positionSec: position, durationSec: model.durationSec) { resume in
                    Task { await model.choose(resume: resume) }
                }
            case .playing:
                PlayerViewController(model: model, subtitle: model.subtitleText, subtitleRaised: model.isPaused, menus: model.menus)
                    .ignoresSafeArea()
                    .overlay {
                        if model.isSwitching {
                            ProgressView()
                                .padding(36)
                                .background(.ultraThinMaterial, in: Circle())
                        }
                    }
                    .overlay(alignment: .top) {
                        if let notice = model.notice {
                            NoticeBanner(message: notice, systemImage: "exclamationmark.circle")
                                .padding(.top, 60)
                                .transition(.move(edge: .top).combined(with: .opacity))
                        }
                    }
                    .animation(Theme.Motion.easeOut, value: model.notice)
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
                coordinator.playerDidClose()
            }
        }
    }
}

/// `AVPlayerViewController` with the system transport bar and info panel, plus the
/// app's Audio / Subtitles / Quality menus, the subtitle overlay and Up Next.
private struct PlayerViewController: UIViewControllerRepresentable {
    let model: VideoPlayerModel
    let subtitle: String?
    let subtitleRaised: Bool
    let menus: PlayerMenuState

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
        if context.coordinator.menus != menus {
            context.coordinator.menus = menus
            controller.transportBarCustomMenuItems = PlayerMenus.make(menus, model: model)
        }
    }

    /// Delegate callbacks arrive on the main thread.
    final class Coordinator: NSObject, AVPlayerViewControllerDelegate {
        let model: VideoPlayerModel
        var subtitleView: SubtitleOverlayView?
        var menus: PlayerMenuState?

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
            timeToSeekAfterUserNavigatedFrom oldTime: CMTime,
            to targetTime: CMTime
        ) -> CMTime {
            MainActor.assumeIsolated { model.resolveUserSeek(from: oldTime, to: targetTime) }
        }
    }
}

/// Artwork-tinted background with a spinner while the stream is being prepared.
private struct PreparingView: View {
    let card: Card

    var body: some View {
        ZStack {
            HeroBackground(card: card)
                .ignoresSafeArea()
                .opacity(0.6)
            VStack(spacing: 28) {
                ProgressView()
                Text(verbatim: card.title)
                    .font(Theme.Typography.headline)
                    .foregroundStyle(Theme.Colors.label2)
            }
        }
    }
}

/// "Resume from 12:34" or "Start Over", over the item's artwork.
private struct ResumePromptView: View {
    let card: Card
    let positionSec: Double
    let durationSec: Double
    let choose: (Bool) -> Void

    @FocusState private var focused: Bool?

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
                if durationSec > 0 {
                    HStack(spacing: 20) {
                        ProgressBar(value: min(1, positionSec / durationSec), height: 8)
                            .frame(width: 420)
                        Text(verbatim: PlaybackTime.remaining(durationSec - positionSec))
                            .font(Theme.Typography.meta)
                            .foregroundStyle(Theme.Colors.label2)
                    }
                }
                HStack(spacing: 28) {
                    Button {
                        choose(true)
                    } label: {
                        Label {
                            Text("Resume from \(PlaybackTime.clock(positionSec))")
                        } icon: {
                            Image(systemName: "play.fill")
                        }
                    }
                    .buttonStyle(PillButtonStyle(kind: .primary))
                    .focused($focused, equals: true)
                    Button {
                        choose(false)
                    } label: {
                        Label("Start Over", systemImage: "arrow.counterclockwise")
                    }
                    .buttonStyle(PillButtonStyle(kind: .glass))
                    .focused($focused, equals: false)
                }
                .padding(.top, 20)
                .focusSection()
            }
            .padding(.horizontal, Theme.Layout.margin)
            .padding(.bottom, 110)
        }
        .defaultFocus($focused, true)
    }
}

/// Why playback could not start or stopped, with Try Again and Close.
private struct PlaybackErrorView: View {
    let card: Card
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
                Text("Can’t Play “\(card.title)”")
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
