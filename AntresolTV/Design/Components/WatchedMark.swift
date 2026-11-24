import SwiftUI

/// The watched mark on a card's artwork: an eye on a dark disc in the middle of the tile,
/// a quarter of its width. Pair it with `watchedDimming(_:isFocused:)` on the same artwork.
struct WatchedMark: View {
    var diameter: CGFloat

    /// A quarter of the tile's width, 52 to 88 pt.
    static func diameter(forWidth width: CGFloat) -> CGFloat {
        min(max(width * Theme.Layout.watchedMarkShare, Theme.Layout.watchedMarkMin), Theme.Layout.watchedMarkMax)
    }

    var body: some View {
        Image(systemName: "eye.fill")
            .resizable()
            .scaledToFit()
            .foregroundStyle(Theme.Colors.label)
            .frame(width: diameter * Theme.Layout.watchedMarkSymbol, height: diameter * Theme.Layout.watchedMarkSymbol)
            .frame(width: diameter, height: diameter)
            .background(Theme.Colors.watchedMarkFill, in: Circle())
            .overlay(Circle().strokeBorder(Theme.Colors.glassBorder, lineWidth: 1))
            .shadow(color: .black.opacity(0.35), radius: 6, y: 2)
            .accessibilityElement()
            .accessibilityLabel(Text("Watched"))
    }
}

extension View {
    /// Dims watched artwork and puts the watched mark in the middle of it, sized by the tile's
    /// `width`. Focus lifts most of the dimming so the focused card stays easy to see; the mark
    /// stays at full strength.
    func watchedDimming(_ watched: Bool, width: CGFloat, isFocused: Bool, cornerRadius: CGFloat = Theme.Radius.card) -> some View {
        overlay {
            if watched {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(.black.opacity(isFocused ? Theme.Colors.watchedDimFocused : Theme.Colors.watchedDim))
                    .allowsHitTesting(false)
            }
        }
        .overlay {
            if watched {
                WatchedMark(diameter: WatchedMark.diameter(forWidth: width))
            }
        }
    }
}
