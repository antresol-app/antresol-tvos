import AVKit
import AntresolKit
import SwiftUI

/// Full-screen player of a stream an addon's way started, presented by the shell for
/// `PlaybackCoordinator.presentedWay`. It opens at once over the title's artwork while the server gets
/// the stream ready (the core's input player can take a while), then plays it in the system player with
/// the stream's subtitles. Menu closes it.
struct WayPlayerView: View {
    let request: PlaybackCoordinator.WayRequest

    @Environment(AppState.self) private var appState
    @Environment(AddonWays.self) private var addons
    @Environment(PlaybackCoordinator.self) private var coordinator
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var model: WayPlayerModel

    init(request: PlaybackCoordinator.WayRequest) {
        self.request = request
        _model = State(initialValue: WayPlayerModel(request: request))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            switch model.state {
            case .preparing:
                PreparingView(card: request.launch.card)
            case .playing:
                WayPlayerController(
                    model: model, subtitle: model.subtitleText, subtitleRaised: model.isPaused, tracks: model.subtitles,
                    selected: model.subtitleIndex, quality: model.qualityChoice, canChooseSource: model.canChooseSource
                )
                    .ignoresSafeArea()
                    .overlay {
                        if model.isSwitching {
                            ProgressView()
                                .padding(36)
                                .glassSurface(in: Circle(), highlighted: false, interactive: false)
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
                PlaybackErrorView(card: request.launch.card, message: message) {
                    Task { await model.retry() }
                } close: {
                    dismiss()
                }
            }
        }
        // «Audio & source…»: the way's own choice over the stream (the shell's sheet is under this cover).
        .sheet(item: $model.chooser, onDismiss: { model.chooserDismissed() }) { launch in
            WaySheetView(launch: launch, player: model)
                .environment(appState)
                .environment(addons)
                .environment(coordinator)
        }
        .task { await model.start(appState: appState, coordinator: coordinator) }
        .onChange(of: model.didFinish) { _, finished in
            if finished { dismiss() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { model.flushProgress() }
        }
        .onDisappear {
            Task {
                await model.stop()
                coordinator.wayPlayerDidClose(request)
            }
        }
    }
}

/// `AVPlayerViewController` with the system transport bar and info panel, the stream's subtitles over
/// the video and, in the bar, what the addon's answer gives: a Subtitles menu when it lists any, a Quality
/// menu when it offers several (and the ref to play another), and «Audio & source…» (the way's own choice).
/// The stream's own audio and subtitle renditions (`AVMediaSelection`) are the system panel's: it lists
/// them by itself, so the answer needs to list none.
private struct WayPlayerController: UIViewControllerRepresentable {
    let model: WayPlayerModel
    let subtitle: String?
    let subtitleRaised: Bool
    let tracks: [SubtitleTrack]
    let selected: Int?
    let quality: StreamQuality?
    let canChooseSource: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = model.player
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
        let menu = Coordinator.MenuState(tracks: tracks, selected: selected, quality: quality, canChooseSource: canChooseSource)
        if context.coordinator.menu != menu {
            context.coordinator.menu = menu
            controller.transportBarCustomMenuItems = menuItems()
        }
    }

    /// Only what has something to choose: no empty menu, and none missing when there is a choice.
    private func menuItems() -> [UIMenuElement] {
        var items: [UIMenuElement] = []
        if !tracks.isEmpty { items.append(subtitleMenu()) }
        if let quality { items.append(qualityMenu(quality)) }
        if canChooseSource {
            items.append(UIAction(
                title: String(localized: "Audio & source…", bundle: .localized), image: UIImage(systemName: "list.bullet")
            ) { [weak model] _ in
                MainActor.assumeIsolated { model?.chooseSource() }
            })
        }
        return items
    }

    /// The qualities the addon offers, by its own names, the playing one ticked; another restarts the
    /// stream at the position it is at.
    private func qualityMenu(_ quality: StreamQuality) -> UIMenu {
        let actions = quality.options.map { name in
            UIAction(title: name, state: name == quality.current ? .on : .off) { [weak model] _ in
                MainActor.assumeIsolated { model?.selectQuality(name) }
            }
        }
        return UIMenu(
            title: String(localized: "Quality", bundle: .localized),
            image: UIImage(systemName: "slider.horizontal.3"),
            options: .singleSelection,
            children: actions
        )
    }

    private func subtitleMenu() -> UIMenu {
        var actions = [
            UIAction(title: String(localized: "Off", bundle: .localized), state: selected == nil ? .on : .off) { [weak model] _ in
                MainActor.assumeIsolated { model?.selectSubtitle(nil) }
            },
        ]
        for track in tracks {
            actions.append(UIAction(title: TrackLabels.describe(track), state: track.index == selected ? .on : .off) { [weak model] _ in
                MainActor.assumeIsolated { model?.selectSubtitle(track.index) }
            })
        }
        return UIMenu(
            title: String(localized: "Subtitles", bundle: .localized),
            image: UIImage(systemName: "captions.bubble"),
            options: .singleSelection,
            children: actions
        )
    }

    final class Coordinator {
        struct MenuState: Equatable {
            var tracks: [SubtitleTrack]
            var selected: Int?
            var quality: StreamQuality?
            var canChooseSource: Bool
        }

        var subtitleView: SubtitleOverlayView?
        var menu: MenuState?
    }
}
