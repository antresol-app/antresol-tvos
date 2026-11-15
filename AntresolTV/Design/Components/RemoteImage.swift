import SwiftUI
import UIKit

/// Server artwork loaded through `ImagePipeline` with the signed-in profile's Bearer header.
/// It fills the frame it is given (aspect fill, clipped); nothing is drawn until the image
/// arrives, so callers put their placeholder behind it.
struct RemoteImage: View {
    /// A server image field (`poster`, `backdrop`, `cover`...). `""` draws nothing.
    let path: String
    /// Paths tried in order when `path` does not load (an episode's frame may be gone with
    /// the media disk, then the series' backdrop shows).
    var fallbacks: [String] = []
    /// Longest side to decode, in pixels. Keep it near the on-screen size.
    var maxPixelSize: CGFloat = 600
    /// Fit inside the frame (a logo) instead of filling it (artwork).
    var fit = false
    /// Called with the decoded image, e.g. to derive a tint colour.
    var onLoad: ((UIImage) -> Void)?

    @Environment(AppState.self) private var appState
    @State private var image: UIImage?

    var body: some View {
        Color.clear
            .overlay {
                if let image = image ?? cachedImage {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: fit ? .fit : .fill)
                        .transition(.opacity)
                }
            }
            .clipped()
            .task(id: candidates) { await load() }
    }

    /// `path`, then the fallbacks, without empty or repeated ones.
    private var candidates: [String] {
        var seen = Set<String>()
        return ([path] + fallbacks).filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    private var urls: [URL] {
        guard let client = appState.client else { return [] }
        return candidates.compactMap { client.urls.image($0) }
    }

    private var cachedImage: UIImage? {
        urls.lazy.compactMap { ImagePipeline.shared.cachedImage(for: $0, maxPixelSize: maxPixelSize) }.first
    }

    private func load() async {
        image = nil
        guard let client = appState.client else { return }
        for url in urls {
            let loaded = await ImagePipeline.shared.image(
                for: url, headers: client.authorizationHeaders(for: url), maxPixelSize: maxPixelSize
            )
            guard !Task.isCancelled else { return }
            if let loaded {
                withAnimation(Theme.Motion.easeOut) { image = loaded }
                onLoad?(loaded)
                return
            }
        }
    }
}
