import SwiftUI

/// A titled horizontal row of cards. The row is a focus section, so moving up or down
/// from any card lands on the nearest card of the neighbouring row.
struct ShelfRow<Data: RandomAccessCollection, ID: Hashable, Cell: View>: View {
    let title: String
    let items: Data
    let id: KeyPath<Data.Element, ID>
    var spacing: CGFloat = Theme.Layout.cardSpacing
    /// Where the title leads ("See All"); without one the title is plain text.
    var destination: Route?
    @ViewBuilder let cell: (Data.Element) -> Cell

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            if let destination {
                NavigationLink(value: destination) {
                    HStack(spacing: 14) {
                        Text(verbatim: title)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 30, weight: .bold))
                    }
                }
                .buttonStyle(ShelfTitleButtonStyle())
                // The capsule's inset keeps the text aligned with the cards.
                .padding(.horizontal, Theme.Layout.margin - 24)
                .accessibilityAddTraits(.isHeader)
            } else {
                Text(verbatim: title)
                    .font(Theme.Typography.sectionTitle)
                    .foregroundStyle(Theme.Colors.label)
                    .padding(.horizontal, Theme.Layout.margin)
                    .accessibilityAddTraits(.isHeader)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: spacing) {
                    ForEach(items, id: id) { item in
                        cell(item)
                    }
                }
                .padding(.horizontal, Theme.Layout.margin)
                // Room for the focus lift and shadow, which the scroll view would clip.
                .padding(.vertical, 24)
            }
            .scrollClipDisabled()
        }
        .focusSection()
    }
}
