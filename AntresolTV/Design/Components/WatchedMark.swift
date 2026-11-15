import SwiftUI

/// The watched mark on a card's artwork: an eye on a small dark disc in the top trailing
/// corner. Pair it with `watchedDimming(_:isFocused:)` on the same artwork.
struct WatchedMark: View {
    var body: some View {
        Image(systemName: "eye.fill")
            .font(.system(size: Theme.Layout.watchedMarkSymbol, weight: .semibold))
            .foregroundStyle(Theme.Colors.label)
            .frame(width: Theme.Layout.watchedMark, height: Theme.Layout.watchedMark)
            .background(Theme.Colors.watchedMarkFill, in: Circle())
            .overlay(Circle().strokeBorder(Theme.Colors.glassBorder, lineWidth: 1))
            .shadow(color: .black.opacity(0.35), radius: 6, y: 2)
            .padding(12)
            .accessibilityElement()
            .accessibilityLabel(Text("Watched"))
    }
}

extension View {
    /// Dims watched artwork and puts the watched mark on it. Focus lifts most of the dimming
    /// so the focused card stays easy to see.
    func watchedDimming(_ watched: Bool, isFocused: Bool, cornerRadius: CGFloat = Theme.Radius.card) -> some View {
        overlay {
            if watched {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(.black.opacity(isFocused ? Theme.Colors.watchedDimFocused : Theme.Colors.watchedDim))
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .topTrailing) {
            if watched { WatchedMark() }
        }
    }
}
