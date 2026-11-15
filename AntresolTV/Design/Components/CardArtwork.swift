import AntresolKit
import SwiftUI

/// Card artwork with the design's placeholder: when an item has no image (or it fails to
/// load), its title is drawn on a gradient whose colour is derived from the title.
struct CardArtwork: View {
    let title: String
    /// Image paths to try, best first; empty strings are skipped.
    let paths: [String]
    var cornerRadius: CGFloat = Theme.Radius.card
    var maxPixelSize: CGFloat = 600
    var showsPlaceholderTitle = true
    /// Where the placeholder title sits; wide cards keep the bottom free for progress.
    var placeholderAlignment: Alignment = .bottomLeading

    var body: some View {
        ZStack(alignment: placeholderAlignment) {
            Theme.Gradients.placeholder(seed: title)
            if showsPlaceholderTitle {
                Text(verbatim: title)
                    .font(Theme.Typography.overlayTitle)
                    .foregroundStyle(.white)
                    .lineLimit(3)
                    .minimumScaleFactor(0.7)
                    .padding(22)
                    .shadow(color: .black.opacity(0.4), radius: 6)
            }
            let available = paths.filter { !$0.isEmpty }
            if let path = available.first {
                // A path that does not load gives way to the next one.
                RemoteImage(path: path, fallbacks: Array(available.dropFirst()), maxPixelSize: maxPixelSize)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}
