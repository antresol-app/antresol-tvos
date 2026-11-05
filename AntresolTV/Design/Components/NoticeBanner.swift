import SwiftUI

/// A short message on a glass capsule: player notices, "Added to queue", "Added to
/// “Road Trip”".
struct NoticeBanner: View {
    let message: String
    var systemImage: String?

    var body: some View {
        Label {
            Text(verbatim: message)
        } icon: {
            if let systemImage {
                Image(systemName: systemImage)
            }
        }
        .font(Theme.Typography.meta)
        .foregroundStyle(Theme.Colors.label)
        .padding(.horizontal, 32)
        .padding(.vertical, 16)
        .background(Theme.Colors.glassFill, in: Capsule())
    }
}
