import SwiftUI

/// A short message on a glass capsule: player notices, "Added to queue", "Added to
/// “Road Trip”".
struct NoticeBanner: View {
    let message: String
    var systemImage: String?

    var body: some View {
        HStack(spacing: 14) {
            if let systemImage {
                Image(systemName: systemImage)
                    .accessibilityHidden(true)
            }
            Text(verbatim: message)
        }
        .font(Theme.Typography.meta)
        .foregroundStyle(Theme.Colors.label)
        .padding(.horizontal, 32)
        .padding(.vertical, 16)
        .glassSurface(in: Capsule(), highlighted: false, interactive: false)
    }
}
