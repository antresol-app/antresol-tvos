import SwiftUI
import UIKit

/// Server artwork loaded through `ImagePipeline` with the signed-in profile's Bearer header.
/// It fills the frame it is given (aspect fill, clipped); nothing is drawn until the image
/// arrives, so callers put their placeholder behind it.
struct RemoteImage: View {
    /// A server image field (`poster`, `backdrop`, `cover`...). `""` draws nothing.
    let path: String
    /// Longest side to decode, in pixels. Keep it near the on-screen size.
    var maxPixelSize: CGFloat = 600
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
                        .scaledToFill()
                        .transition(.opacity)
                }
            }
            .clipped()
            .task(id: path) { await load() }
    }

    private var url: URL? {
        appState.client?.urls.image(path)
    }

    private var cachedImage: UIImage? {
        url.flatMap { ImagePipeline.shared.cachedImage(for: $0, maxPixelSize: maxPixelSize) }
    }

    private func load() async {
        image = nil
        guard let url, let client = appState.client else {
            image = nil
            return
        }
        let loaded = await ImagePipeline.shared.image(
            for: url, headers: client.authorizationHeaders(for: url), maxPixelSize: maxPixelSize
        )
        guard !Task.isCancelled else { return }
        withAnimation(Theme.Motion.easeOut) { image = loaded }
        if let loaded { onLoad?(loaded) }
    }
}
