import SwiftUI

/// The row of pill buttons on a detail header. Long labels (Russian, an episode with every
/// action) can need more than the header's width: the row then scrolls sideways as focus
/// moves instead of truncating labels.
struct ActionRow<Content: View>: View {
    var spacing: CGFloat = 24
    @ViewBuilder let content: () -> Content

    /// Room around the pills for their focus scale and shadow, which the scroll view clips.
    private static var focusRoom: CGFloat { 32 }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: spacing) {
                content()
            }
            .padding(Self.focusRoom)
        }
        .padding(-Self.focusRoom)
        .focusSection()
    }
}
