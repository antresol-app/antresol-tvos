import AntresolKit
import SwiftUI

/// The Search tab: the native tvOS search field and keyboard, Browse tiles while nothing
/// is typed, and results grouped by kind (movies, shows, music, books) as they arrive.
struct SearchView: View {
    /// Switches the shell to a library tab (Browse tiles), and the Books tab to a section.
    let onBrowse: (ShellTab, BooksView.Pane?) -> Void

    @Environment(AppState.self) private var appState
    @State private var query = ""
    @State private var model = SearchModel()

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            content
                .padding(.bottom, 100)
        }
        .scrollClipDisabled()
        .ignoresSafeArea(edges: .horizontal)
        .background(Theme.Colors.background.ignoresSafeArea())
        .searchable(text: $query, prompt: Text("Movies, music and books"))
        .task(id: query) { await model.search(query, using: appState) }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .idle:
            browse
        case .searching:
            ProgressView()
                .frame(maxWidth: .infinity, minHeight: 300)
        case .failed(let message):
            ErrorStateView(message: message) {
                Task { await model.search(query, using: appState) }
            }
            .frame(minHeight: 500)
        case .results(let groups):
            if groups.isEmpty {
                VStack(spacing: 20) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 64))
                        .foregroundStyle(Theme.Colors.label3)
                    Text(verbatim: String(localized: "No results for “\(query)”"))
                        .font(Theme.Typography.headline)
                        .foregroundStyle(Theme.Colors.label)
                    Text("Try another title, artist or author.")
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.Colors.label2)
                }
                .frame(maxWidth: .infinity, minHeight: 360)
            } else {
                results(groups)
            }
        }
    }

    private func results(_ groups: [SearchGroup]) -> some View {
        LazyVStack(alignment: .leading, spacing: Theme.Layout.shelfSpacing - 16) {
            ForEach(groups) { group in
                ShelfRow(title: group.title, items: group.entries, id: \.id) { entry in
                    NavigationLink(value: Route.item(entry.destination)) {
                        PosterCard(card: entry.card)
                    }
                    .buttonStyle(CardButtonStyle())
                }
            }
        }
        .padding(.top, 20)
    }

    // MARK: Browse

    private var browse: some View {
        VStack(alignment: .leading, spacing: 28) {
            Text("Browse")
                .font(Theme.Typography.sectionTitle)
                .foregroundStyle(Theme.Colors.label)
                .accessibilityAddTraits(.isHeader)
            HStack(spacing: 32) {
                ForEach(BrowseTile.all) { tile in
                    Button {
                        onBrowse(tile.tab, tile.booksPane)
                    } label: {
                        BrowseTileView(tile: tile)
                    }
                    .buttonStyle(CardButtonStyle())
                }
            }
            .focusSection()
            Text("Search for movies, music and books in your library.")
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Colors.label2)
                .padding(.top, 24)
        }
        .padding(.horizontal, Theme.Layout.margin)
        .padding(.top, 20)
    }
}

/// A colourful category tile on the Search tab.
private struct BrowseTile: Identifiable {
    let id: String
    let title: LocalizedStringKey
    let systemImage: String
    let colors: (UInt32, UInt32)
    let tab: ShellTab
    var booksPane: BooksView.Pane?

    static let all: [BrowseTile] = [
        BrowseTile(id: "movies", title: "Movies", systemImage: "film", colors: (0xFF375F, 0xFF9F0A), tab: .movies),
        BrowseTile(id: "shows", title: "TV Shows", systemImage: "tv", colors: (0x5E5CE6, 0xBF5AF2), tab: .shows),
        BrowseTile(id: "music", title: "Music", systemImage: "music.note", colors: (0xBF5AF2, 0xFF375F), tab: .music),
        BrowseTile(id: "books", title: "Books", systemImage: "book", colors: (0xFF9F0A, 0xFFD60A), tab: .books, booksPane: .books),
        BrowseTile(id: "audiobooks", title: "Audiobooks", systemImage: "headphones", colors: (0x30D158, 0x00C7BE), tab: .books, booksPane: .audiobooks),
        BrowseTile(id: "comics", title: "Manga & Comics", systemImage: "books.vertical", colors: (0x00C7BE, 0x0A84FF), tab: .books, booksPane: .comics),
    ]
}

private struct BrowseTileView: View {
    let tile: BrowseTile
    @Environment(\.isCardFocused) private var isFocused

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(tile.title)
                .font(Theme.Typography.headline)
                .foregroundStyle(.white)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
            Image(systemName: tile.systemImage)
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
        }
        .padding(24)
        .frame(width: 262, height: 160, alignment: .bottomLeading)
        .background(
            LinearGradient(
                colors: [Color(hex: tile.colors.0), Color(hex: tile.colors.1)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
        )
        .cardLift(isFocused: isFocused)
    }
}
