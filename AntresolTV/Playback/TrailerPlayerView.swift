import AVKit
import AntresolKit
import Observation
import SwiftUI

/// Full-screen player for a trailer the server plays itself (`Trailer.play`), presented by
/// the shell for `PlaybackCoordinator.presentedTrailer`. It opens at once on the title's
/// artwork with a spinner and the trailer's name while the server gets the file ready,
/// then plays it in the system player. Menu closes it. Nothing is reported: no progress,
/// no Continue Watching, no Up Next.
struct TrailerPlayerView: View {
    let request: PlaybackCoordinator.TrailerRequest

    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var model: TrailerPlayerModel

    init(request: PlaybackCoordinator.TrailerRequest) {
        self.request = request
        _model = State(initialValue: TrailerPlayerModel(trailer: request.trailer))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            switch model.state {
            case .loading:
                PreparingView(card: request.card, title: model.title)
            case .playing:
                TrailerPlayerController(player: model.player)
                    .ignoresSafeArea()
            case .failed(let message):
                PlaybackErrorView(card: request.card, title: model.title, message: message) {
                    model.retry()
                } close: {
                    dismiss()
                }
            }
        }
        .task(id: model.attempt) { await model.load(appState: appState) }
        .onChange(of: model.didFinish) { _, finished in
            if finished { dismiss() }
        }
        .onDisappear { model.stop() }
    }
}

/// The trailer request, its busy retries and the player.
@MainActor
@Observable
final class TrailerPlayerModel {
    enum State: Equatable {
        case loading
        case playing
        case failed(String)
    }

    let trailer: Trailer
    let player = AVPlayer()
    private(set) var state: State = .loading
    /// Bumped by Try Again; the view restarts `load` for each value.
    private(set) var attempt = 0
    /// The trailer played to its end, or the profile was signed out: the player closes.
    private(set) var didFinish = false

    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var statusObserver: NSKeyValueObservation?

    init(trailer: Trailer) {
        self.trailer = trailer
    }

    /// The trailer's name, else "Trailer" or "Teaser".
    var title: String { TrailerButton.name(of: trailer) }

    func retry() {
        state = .loading
        attempt += 1
    }

    func load(appState: AppState) async {
        state = .loading
        guard let client = appState.client else {
            didFinish = true
            return
        }
        do {
            let playback = try await client.playTrailer(trailer)
            try Task.checkCancellation()
            guard let url = client.urls.trailer(playback) else {
                throw APIError.decoding("trailer url")
            }
            play(url)
        } catch is CancellationError {
            // Closed while waiting.
        } catch {
            guard !Task.isCancelled else { return }
            if let message = Self.message(for: error, appState: appState) {
                state = .failed(message)
            } else {
                didFinish = true
            }
        }
    }

    func stop() {
        teardown()
        player.pause()
        player.replaceCurrentItem(with: nil)
    }

    private func play(_ url: URL) {
        teardown()
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        let item = AVPlayerItem(url: url)
        let title = AVMutableMetadataItem()
        title.identifier = .commonIdentifierTitle
        title.value = self.title as NSString
        title.extendedLanguageTag = "und"
        item.externalMetadata = [title]
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.didFinish = true }
            },
            center.addObserver(forName: AVPlayerItem.failedToPlayToEndTimeNotification, object: item, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.itemFailed() }
            },
        ]
        statusObserver = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            let failed = item.status == .failed
            Task { @MainActor in
                if failed { self?.itemFailed() }
            }
        }
        player.replaceCurrentItem(with: item)
        state = .playing
        player.play()
    }

    private func itemFailed() {
        guard state == .playing else { return }
        stop()
        state = .failed(String(localized: "The trailer couldn’t be played. Check the connection to the server and try again.", bundle: .localized))
    }

    private func teardown() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        statusObserver?.invalidate()
        statusObserver = nil
    }

    /// What to show for a failed request; nil when the profile was signed out (`401`).
    /// The server's own (translated) message wins; a busy server and an unknown trailer
    /// get a trailer-specific one.
    static func message(for error: Error, appState: AppState) -> String? {
        if let error = error as? APIError, error.serverMessage?.isEmpty ?? true {
            switch error.statusCode {
            case 503:
                return String(localized: "The server is busy preparing other trailers. Try again in a moment.", bundle: .localized)
            case 404:
                return String(localized: "This trailer is no longer available.", bundle: .localized)
            default:
                break
            }
        }
        return appState.message(for: error)
    }
}

/// `AVPlayerViewController` with the system transport bar and info panel, nothing else.
private struct TrailerPlayerController: UIViewControllerRepresentable {
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
