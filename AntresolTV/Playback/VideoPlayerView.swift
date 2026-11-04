import AVKit
import SwiftUI

/// Full-screen player presented by the shell for `PlaybackCoordinator.presented`.
struct VideoPlayerView: View {
    let request: PlaybackCoordinator.Request

    @Environment(AppState.self) private var appState
    @Environment(PlaybackCoordinator.self) private var coordinator
    @Environment(\.dismiss) private var dismiss
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
                VStack(spacing: 28) {
                    ProgressView()
                    Text(verbatim: model.title)
                        .font(Theme.Typography.headline)
                        .foregroundStyle(Theme.Colors.label2)
                }
            case .playing:
                PlayerViewController(player: model.player)
                    .ignoresSafeArea()
            case .failed(let message):
                ErrorStateView(message: message) {
                    Task { await model.start(appState: appState, coordinator: coordinator) }
                }
            }
        }
        .task { await model.start(appState: appState, coordinator: coordinator) }
        .onChange(of: model.didPlayToEnd) { _, ended in
            if ended { dismiss() }
        }
        .onDisappear {
            Task {
                await model.stop()
                coordinator.playerDidClose()
            }
        }
    }
}

/// `AVPlayerViewController` with the system transport bar, info panel and Siri remote
/// gestures.
private struct PlayerViewController: UIViewControllerRepresentable {
    let player: AVPlayer

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        if controller.player !== player {
            controller.player = player
        }
    }
}
