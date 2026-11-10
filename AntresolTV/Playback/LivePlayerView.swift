import AVFoundation
import AntresolKit
import SwiftUI
import UIKit

/// The full-screen live player presented by the shell for
/// `PlaybackCoordinator.presentedChannel`. The picture fills the screen; the channel panel
/// (logo, "10 · Comedies", Live, what is on with its progress, what is next) comes up on
/// every change and on Select. Up and Down (a click or a swipe, or a remote's channel
/// buttons) zap to the next or previous channel; Menu leaves.
struct LivePlayerView: View {
    let request: PlaybackCoordinator.LiveRequest

    @Environment(AppState.self) private var appState
    @Environment(PlaybackCoordinator.self) private var coordinator
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var model: LivePlayerModel

    init(request: PlaybackCoordinator.LiveRequest) {
        self.request = request
        _model = State(initialValue: LivePlayerModel(request: request))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            switch model.state {
            case .failed(let message):
                LiveErrorView(model: model, message: message) { dismiss() }
            default:
                LivePlayerSurface(model: model) { dismiss() }
                    .ignoresSafeArea()
                if case .connecting(let isStarting) = model.state {
                    LiveConnectingView(model: model, isStarting: isStarting)
                        .allowsHitTesting(false)
                }
                if model.showsInfo {
                    LiveInfoPanel(model: model)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .allowsHitTesting(false)
                }
            }
        }
        .animation(Theme.Motion.easeOut, value: model.showsInfo)
        .animation(Theme.Motion.easeOut, value: model.state)
        .task { model.start(appState: appState, coordinator: coordinator) }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background: model.suspend()
            case .active: model.resumeFromBackground()
            default: break
            }
        }
        .onDisappear {
            model.stop()
            coordinator.liveChannelDidClose()
        }
    }
}

// MARK: - Panels

/// The channel panel along the bottom edge.
private struct LiveInfoPanel: View {
    let model: LivePlayerModel

    @Environment(\.locale) private var locale

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let onAir = model.onAir(at: context.date)
            VStack {
                Spacer()
                HStack(alignment: .center, spacing: 40) {
                    ChannelLogo(model.channel)
                        .frame(width: 256, height: 144)
                        .shadow(color: .black.opacity(0.5), radius: 20, y: 10)

                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 20) {
                            Text(verbatim: model.channel.label)
                                .font(Theme.Typography.headline)
                                .foregroundStyle(Theme.Colors.label)
                                .lineLimit(1)
                            LiveBadge()
                        }
                        if let now = onAir.now {
                            Text(verbatim: now.title)
                                .font(Theme.Typography.pageTitle)
                                .foregroundStyle(Theme.Colors.label)
                                .lineLimit(1)
                                .minimumScaleFactor(0.6)
                            if !now.subtitle.isEmpty {
                                Text(verbatim: now.subtitle)
                                    .font(Theme.Typography.meta)
                                    .foregroundStyle(Theme.Colors.label2)
                                    .lineLimit(1)
                            }
                            HStack(spacing: 24) {
                                Text(verbatim: "\(clock(now.start))–\(clock(now.end))")
                                    .font(Theme.Typography.meta)
                                    .monospacedDigit()
                                    .foregroundStyle(Theme.Colors.label2)
                                ProgressBar(value: now.progress(at: context.date), height: 8)
                                    .frame(width: 460)
                            }
                            .padding(.top, 4)
                        } else {
                            Text("Nothing on now")
                                .font(Theme.Typography.pageTitle)
                                .foregroundStyle(Theme.Colors.label)
                        }
                        if let next = onAir.next {
                            Text(verbatim: String(localized: "At \(clock(next.start)) — \(next.fullTitle)", bundle: .localized))
                                .font(Theme.Typography.meta)
                                .foregroundStyle(Theme.Colors.label2)
                                .lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    ChannelArrows()
                }
                .padding(.horizontal, Theme.Layout.margin)
                .padding(.top, 140)
                .padding(.bottom, 80)
                .background(
                    LinearGradient(colors: [.clear, .black.opacity(0.65), .black.opacity(0.9)], startPoint: .top, endPoint: .bottom)
                )
            }
        }
        .ignoresSafeArea()
        .accessibilityElement(children: .combine)
    }

    private func clock(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(locale))
    }
}

/// "LIVE" with a red dot.
private struct LiveBadge: View {
    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(Theme.Colors.red)
                .frame(width: 14, height: 14)
            Text("Live")
                .font(Theme.Typography.eyebrow)
                .tracking(2)
                .textCase(.uppercase)
                .foregroundStyle(Theme.Colors.label)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
        .glassSurface(in: Capsule(), highlighted: false, interactive: false)
    }
}

/// The hint that Up and Down change the channel.
private struct ChannelArrows: View {
    var body: some View {
        VStack(spacing: 22) {
            Image(systemName: "chevron.up")
                .accessibilityLabel(Text("Next Channel"))
            Image(systemName: "chevron.down")
                .accessibilityLabel(Text("Previous Channel"))
        }
        .font(.system(size: 30, weight: .semibold))
        .foregroundStyle(Theme.Colors.label2)
        .padding(.horizontal, 22)
        .padding(.vertical, 26)
        .glassSurface(in: Capsule(), highlighted: false, interactive: false)
    }
}

/// The programme's backdrop, dimmed, with a spinner while the stream is being prepared.
private struct LiveConnectingView: View {
    let model: LivePlayerModel
    let isStarting: Bool

    var body: some View {
        ZStack {
            if let backdrop = model.onAir(at: Date()).now?.backdrop, !backdrop.isEmpty {
                RemoteImage(path: backdrop, maxPixelSize: 1920)
                    .opacity(0.35)
                    .ignoresSafeArea()
            }
            VStack(spacing: 28) {
                ProgressView()
                if isStarting {
                    Text("Starting the channel…")
                        .font(Theme.Typography.headline)
                        .foregroundStyle(Theme.Colors.label2)
                }
            }
            .padding(.bottom, 200)
        }
    }
}

/// Why the channel cannot be shown, with Try Again and Close. Up and Down still zap.
private struct LiveErrorView: View {
    let model: LivePlayerModel
    let message: String
    let close: () -> Void

    var body: some View {
        VStack(spacing: 30) {
            ChannelLogo(model.channel)
                .frame(width: 256, height: 144)
            Text(verbatim: model.channel.label)
                .font(Theme.Typography.headline)
                .foregroundStyle(Theme.Colors.label2)
            Text("The channel can’t be shown")
                .font(Theme.Typography.sectionTitle)
                .foregroundStyle(Theme.Colors.label)
            if message != String(localized: "The channel can’t be shown", bundle: .localized) {
                Text(verbatim: message)
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Colors.label2)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 1100)
            }
            GlassGroup(spacing: 28) {
                HStack(spacing: 28) {
                    Button {
                        model.retry()
                    } label: {
                        Label("Try Again", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(PillButtonStyle(kind: .primary))
                    Button(action: close) {
                        Text("Close")
                    }
                    .buttonStyle(PillButtonStyle(kind: .glass))
                }
            }
            .padding(.top, 10)
            .focusSection()
        }
        .padding(Theme.Layout.margin)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onMoveCommand { direction in
            switch direction {
            case .up: model.zap(1)
            case .down: model.zap(-1)
            default: break
            }
        }
        .onExitCommand(perform: close)
    }
}

// MARK: - Picture and remote

/// The picture (an `AVPlayerLayer`, no transport bar: live has nothing to scrub) and the
/// remote: Up / Down and the channel buttons zap, Select shows or hides the panel,
/// Play/Pause pauses, Menu leaves.
private struct LivePlayerSurface: UIViewControllerRepresentable {
    let model: LivePlayerModel
    let exit: () -> Void

    func makeUIViewController(context: Context) -> LivePlayerController {
        let controller = LivePlayerController(player: model.player)
        update(controller)
        return controller
    }

    func updateUIViewController(_ controller: LivePlayerController, context: Context) {
        update(controller)
    }

    private func update(_ controller: LivePlayerController) {
        let model = model
        controller.onZap = { model.zap($0) }
        controller.onSelect = { model.toggleInfo() }
        controller.onInfo = { model.showInfo() }
        controller.onPlayPause = { model.togglePause() }
        controller.onExit = exit
        controller.view.accessibilityLabel = model.channel.label
    }
}

final class LivePlayerController: UIViewController {
    var onZap: (Int) -> Void = { _ in }
    var onSelect: () -> Void = {}
    var onInfo: () -> Void = {}
    var onPlayPause: () -> Void = {}
    var onExit: () -> Void = {}

    private let player: AVPlayer

    init(player: AVPlayer) {
        self.player = player
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func loadView() {
        let view = PlayerLayerView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspect
        view.backgroundColor = .black
        view.isAccessibilityElement = true
        view.accessibilityCustomActions = [
            UIAccessibilityCustomAction(name: String(localized: "Next Channel", bundle: .localized)) { [weak self] _ in
                self?.onZap(1)
                return true
            },
            UIAccessibilityCustomAction(name: String(localized: "Previous Channel", bundle: .localized)) { [weak self] _ in
                self?.onZap(-1)
                return true
            },
        ]
        self.view = view
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        // Swipes on the Siri Remote's touch surface; clicks arrive as presses.
        for (direction, step) in [(UISwipeGestureRecognizer.Direction.up, 1), (.down, -1)] {
            let swipe = UISwipeGestureRecognizer(target: self, action: step > 0 ? #selector(swipedUp) : #selector(swipedDown))
            swipe.direction = direction
            view.addGestureRecognizer(swipe)
        }
    }

    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        [view]
    }

    @objc private func swipedUp() { onZap(1) }
    @objc private func swipedDown() { onZap(-1) }

    private static let handledPresses: Set<UIPress.PressType> = [
        .upArrow, .downArrow, .leftArrow, .rightArrow, .pageUp, .pageDown, .select, .playPause, .menu,
    ]

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let others = presses.filter { !Self.handledPresses.contains($0.type) }
        for press in presses where Self.handledPresses.contains(press.type) {
            switch press.type {
            case .upArrow, .pageUp: onZap(1)
            case .downArrow, .pageDown: onZap(-1)
            case .leftArrow, .rightArrow: onInfo()
            case .select: onSelect()
            case .playPause: onPlayPause()
            case .menu: onExit()
            default: break
            }
        }
        if !others.isEmpty { super.pressesBegan(others, with: event) }
    }

    // The handled presses end here too, so nothing up the chain acts on them.
    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let others = presses.filter { !Self.handledPresses.contains($0.type) }
        if !others.isEmpty { super.pressesEnded(others, with: event) }
    }

    override func pressesChanged(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let others = presses.filter { !Self.handledPresses.contains($0.type) }
        if !others.isEmpty { super.pressesChanged(others, with: event) }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let others = presses.filter { !Self.handledPresses.contains($0.type) }
        if !others.isEmpty { super.pressesCancelled(others, with: event) }
    }
}

/// A focusable view backed by an `AVPlayerLayer`.
private final class PlayerLayerView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }

    var playerLayer: AVPlayerLayer {
        layer as! AVPlayerLayer
    }

    override var canBecomeFocused: Bool { true }
}
