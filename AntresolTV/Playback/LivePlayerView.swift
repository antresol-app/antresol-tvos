import AVFoundation
import AntresolKit
import SwiftUI
import UIKit

/// The full-screen live player presented by the shell for
/// `PlaybackCoordinator.presentedChannel`. The picture fills the screen; the channel banner
/// (logo, "10 · Comedies", Live, what is on with its progress, what is next) slides in on
/// every change and on Select and fades after 5 s. Up (a click or a swipe) and the remote's
/// channel buttons zap; Down opens the mini-guide, a row of the section's channels with
/// focus on the current one; Menu closes the mini-guide first, then leaves. A zap holds
/// the old picture, dimmed under the banner, until the new channel's first frame.
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
                if model.isHoldingFrame {
                    // The previous channel's last frame, dimmed, with a quiet spinner.
                    Color.black.opacity(0.45)
                        .ignoresSafeArea()
                        .overlay {
                            ProgressView()
                                .padding(36)
                                .glassSurface(in: Circle(), highlighted: false, interactive: false)
                                .padding(.bottom, 200)
                        }
                        .allowsHitTesting(false)
                        .transition(.opacity)
                } else if case .connecting(let isStarting) = model.state {
                    LiveConnectingView(model: model, isStarting: isStarting)
                        .allowsHitTesting(false)
                }
                if model.showsInfo {
                    LiveBanner(model: model)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .allowsHitTesting(false)
                }
                if model.showsGuide {
                    LiveChannelRail(model: model)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
        .animation(Theme.Motion.slowEaseOut, value: model.showsInfo)
        .animation(Theme.Motion.slowEaseOut, value: model.showsGuide)
        .animation(Theme.Motion.easeOut, value: model.isHoldingFrame)
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

// MARK: - Banner and mini-guide

/// The channel banner: a glass panel along the bottom edge, the app's player chrome.
private struct LiveBanner: View {
    let model: LivePlayerModel

    @Environment(\.locale) private var locale

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let onAir = model.onAir(at: context.date)
            VStack {
                Spacer()
                HStack(alignment: .center, spacing: 40) {
                    ChannelLogo(model.channel, cornerRadius: Theme.Radius.control)
                        .frame(width: 240, height: 135)
                        .shadow(color: .black.opacity(0.35), radius: 14, y: 6)

                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 18) {
                            Text(verbatim: model.channel.label)
                                .font(Theme.Typography.headline)
                                .foregroundStyle(Theme.Colors.label)
                                .lineLimit(1)
                            LiveBadge()
                        }
                        if let now = onAir.now {
                            Text(verbatim: now.fullTitle)
                                .font(Theme.Typography.sectionTitle)
                                .foregroundStyle(Theme.Colors.label)
                                .lineLimit(1)
                            HStack(spacing: 24) {
                                ProgressBar(value: now.progress(at: context.date), height: 8)
                                    .frame(width: 420)
                                Text(verbatim: now.timeRange(locale))
                                    .font(Theme.Typography.meta)
                                    .monospacedDigit()
                                    .foregroundStyle(Theme.Colors.label2)
                            }
                            .padding(.top, 4)
                        } else {
                            Text("Nothing on now")
                                .font(Theme.Typography.sectionTitle)
                                .foregroundStyle(Theme.Colors.label)
                        }
                        if let next = onAir.next {
                            Text(verbatim: next.nextLine(locale))
                                .font(Theme.Typography.meta)
                                .foregroundStyle(Theme.Colors.label2)
                                .lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    RemoteHints()
                }
                .padding(32)
                // A dark backing keeps the glass legible over a bright, saturated picture.
                .background(.black.opacity(0.3), in: RoundedRectangle(cornerRadius: Theme.Radius.sheet + 12, style: .continuous))
                .glassSurface(in: RoundedRectangle(cornerRadius: Theme.Radius.sheet + 12, style: .continuous), highlighted: false, interactive: false)
                .padding(.horizontal, Theme.Layout.margin)
                .padding(.bottom, 60)
            }
            .background(alignment: .bottom) { BottomScrim(height: 520) }
        }
        .ignoresSafeArea()
        .accessibilityElement(children: .combine)
    }
}

/// What the remote does here: Up for the next channel, Down for the channel row.
private struct RemoteHints: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Next Channel", systemImage: "chevron.up")
            Label("Channels", systemImage: "chevron.down")
        }
        .labelStyle(HintLabelStyle())
        .font(Theme.Typography.cardMeta)
        .foregroundStyle(Theme.Colors.label2)
        .padding(.trailing, 12)
    }
}

private struct HintLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 14) {
            configuration.icon
                .font(.system(size: 20, weight: .bold))
                .frame(width: 44, height: 44)
                .glassSurface(in: Circle(), highlighted: false, interactive: false)
            configuration.title
        }
    }
}

/// A soft dark fade up from the bottom edge, so text and glass read over a bright picture.
private struct BottomScrim: View {
    let height: CGFloat
    /// The darkness at the bottom edge.
    var depth: Double = 0.7

    var body: some View {
        LinearGradient(colors: [.clear, .black.opacity(depth * 0.55), .black.opacity(depth)], startPoint: .top, endPoint: .bottom)
            .frame(height: height)
            .frame(maxWidth: .infinity)
            .allowsHitTesting(false)
    }
}

/// The mini-guide: the current section's channels as a row of channel cards along the
/// bottom, focus on the current channel. Select switches to a card's channel; Up or Menu
/// closes the row.
private struct LiveChannelRail: View {
    let model: LivePlayerModel

    @FocusState private var focused: Int?
    /// Fixed when the row opens, so a refresh or a zap does not move it under the focus.
    @State private var strip: ChannelStrip?

    private static let cardWidth: CGFloat = 420

    var body: some View {
        let strip = strip ?? model.strip
        VStack(alignment: .leading, spacing: 8) {
            Spacer()
            Text(verbatim: strip.category.isEmpty ? String(localized: "Channels", bundle: .localized) : strip.category)
                .font(Theme.Typography.sectionTitle)
                .foregroundStyle(Theme.Colors.label)
                .padding(.horizontal, Theme.Layout.margin)
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: Theme.Layout.cardSpacing) {
                        ForEach(fresh(strip.channels)) { channel in
                            Button {
                                model.tune(to: channel)
                            } label: {
                                ChannelCard(channel: channel, width: Self.cardWidth)
                                    .overlay(alignment: .topTrailing) {
                                        if channel.id == model.channel.id { NowWatchingMark() }
                                    }
                            }
                            .buttonStyle(CardButtonStyle())
                            .focused($focused, equals: channel.id)
                            .id(channel.id)
                        }
                    }
                    .padding(.horizontal, Theme.Layout.margin)
                    .padding(.vertical, 28)
                }
                .scrollClipDisabled()
                // A horizontal scroll view takes all the height it is offered; the row
                // keeps to its cards so it sits on the bottom edge.
                .fixedSize(horizontal: false, vertical: true)
                .onAppear {
                    self.strip = model.strip
                    proxy.scrollTo(model.channel.id, anchor: .center)
                    focused = model.channel.id
                }
            }
            .defaultFocus($focused, strip.current.id)
            .padding(.bottom, 30)
        }
        // Captions sit straight on the picture: a deeper fade than the banner's.
        .background(alignment: .bottom) { BottomScrim(height: 760, depth: 0.9) }
        .ignoresSafeArea()
        .focusSection()
        .onExitCommand { model.hideGuide() }
        .onMoveCommand { direction in
            if direction == .up { model.hideGuide() }
        }
    }

    /// The strip's channels as the latest list has them (what is on moves on).
    private func fresh(_ channels: [Channel]) -> [Channel] {
        channels.map { channel in model.channels.first { $0.id == channel.id } ?? channel }
    }
}

/// Marks the channel on screen in the mini-guide.
private struct NowWatchingMark: View {
    var body: some View {
        Image(systemName: "play.fill")
            .font(.system(size: 18, weight: .bold))
            .foregroundStyle(Theme.Colors.label)
            .frame(width: 48, height: 48)
            .glassSurface(in: Circle(), highlighted: false, interactive: false)
            .padding(16)
            .accessibilityLabel(Text("Now Watching"))
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
                    .padding(36)
                    .glassSurface(in: Circle(), highlighted: false, interactive: false)
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

/// The picture (two `AVPlayerLayer`s, the one on screen above the one a zap loads into; no
/// transport bar: live has nothing to scrub) and the remote: Up and the channel buttons
/// zap, Down opens the mini-guide, Select shows or hides the banner, Play/Pause pauses,
/// Menu leaves. While the mini-guide is up the picture gives up focus and the presses.
private struct LivePlayerSurface: UIViewControllerRepresentable {
    let model: LivePlayerModel
    let exit: () -> Void

    func makeUIViewController(context: Context) -> LivePlayerController {
        let controller = LivePlayerController(layers: model.layers)
        update(controller)
        return controller
    }

    func updateUIViewController(_ controller: LivePlayerController, context: Context) {
        update(controller)
    }

    private func update(_ controller: LivePlayerController) {
        let model = model
        controller.onZap = { model.zap($0) }
        controller.onGuide = { model.showGuide() }
        controller.onSelect = { model.toggleInfo() }
        controller.onInfo = { model.showInfo() }
        controller.onPlayPause = { model.togglePause() }
        controller.onExit = exit
        controller.show(layer: model.front)
        controller.takesRemote = !model.showsGuide
        controller.view.accessibilityLabel = model.channel.label
    }
}

final class LivePlayerController: UIViewController {
    var onZap: (Int) -> Void = { _ in }
    var onGuide: () -> Void = {}
    var onSelect: () -> Void = {}
    var onInfo: () -> Void = {}
    var onPlayPause: () -> Void = {}
    var onExit: () -> Void = {}

    /// False while the mini-guide has focus: the picture is not focusable then, so moving
    /// focus up from the row cannot land on it.
    var takesRemote = true {
        didSet {
            guard takesRemote != oldValue else { return }
            pictureView.isFocusable = takesRemote
            if takesRemote {
                setNeedsFocusUpdate()
                updateFocusIfNeeded()
            }
        }
    }

    private let layers: [AVPlayerLayer]
    private var pictureView: PictureView { view as! PictureView }

    init(layers: [AVPlayerLayer]) {
        self.layers = layers
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func loadView() {
        let view = PictureView(layers: layers)
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
            UIAccessibilityCustomAction(name: String(localized: "Channels", bundle: .localized)) { [weak self] _ in
                self?.onGuide()
                return true
            },
        ]
        self.view = view
    }

    /// Puts the layer at `index` on top; the other one sits underneath.
    func show(layer index: Int) {
        for (i, layer) in layers.enumerated() {
            layer.zPosition = i == index ? 1 : 0
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        // Swipes on the Siri Remote's touch surface; clicks arrive as presses.
        for (direction, action) in [(UISwipeGestureRecognizer.Direction.up, #selector(swipedUp)), (.down, #selector(swipedDown))] {
            let swipe = UISwipeGestureRecognizer(target: self, action: action)
            swipe.direction = direction
            view.addGestureRecognizer(swipe)
        }
    }

    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        [view]
    }

    @objc private func swipedUp() {
        if takesRemote { onZap(1) }
    }

    @objc private func swipedDown() {
        if takesRemote { onGuide() }
    }

    private static let handledPresses: Set<UIPress.PressType> = [
        .upArrow, .downArrow, .leftArrow, .rightArrow, .pageUp, .pageDown, .select, .playPause, .menu,
    ]

    private func handled(_ presses: Set<UIPress>) -> Set<UIPress> {
        takesRemote ? presses.filter { Self.handledPresses.contains($0.type) } : []
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let mine = handled(presses)
        for press in mine {
            switch press.type {
            case .upArrow, .pageUp: onZap(1)
            case .pageDown: onZap(-1)
            case .downArrow: onGuide()
            case .leftArrow, .rightArrow: onInfo()
            case .select: onSelect()
            case .playPause: onPlayPause()
            case .menu: onExit()
            default: break
            }
        }
        let others = presses.subtracting(mine)
        if !others.isEmpty { super.pressesBegan(others, with: event) }
    }

    // The handled presses end here too, so nothing up the chain acts on them.
    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let others = presses.subtracting(handled(presses))
        if !others.isEmpty { super.pressesEnded(others, with: event) }
    }

    override func pressesChanged(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let others = presses.subtracting(handled(presses))
        if !others.isEmpty { super.pressesChanged(others, with: event) }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let others = presses.subtracting(handled(presses))
        if !others.isEmpty { super.pressesCancelled(others, with: event) }
    }
}

/// A focusable view holding the player layers, each filling it.
private final class PictureView: UIView {
    private let layers: [AVPlayerLayer]
    var isFocusable = true

    init(layers: [AVPlayerLayer]) {
        self.layers = layers
        super.init(frame: .zero)
        layers.forEach(layer.addSublayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for playerLayer in layers {
            playerLayer.frame = bounds
        }
        CATransaction.commit()
    }

    override var canBecomeFocused: Bool { isFocusable }
}
