import AntresolKit
import SwiftUI

/// The Movies and TV Shows tabs: a large page title, the sort pill (Recently Added /
/// By Title / By Year) and a poster grid that loads further pages as focus nears the end.
struct LibraryView: View {
    let kind: ItemKind
    let title: LocalizedStringKey

    @Environment(AppState.self) private var appState
    @Environment(PlaybackCoordinator.self) private var playback
    @AppStorage private var storedSort: String
    /// `/api/items` of this section, sixty at a time (ten full rows of the grid).
    @State private var list = PagedList<Card>(key: \.uniqueKey)

    init(kind: ItemKind, title: LocalizedStringKey) {
        self.kind = kind
        self.title = title
        let key = "library.sort.\(kind.rawValue)"
        _storedSort = AppStorage(wrappedValue: ItemSort.recent.rawValue, key)
    }

    /// Loads the first page. A new sort order starts over; otherwise (the tab appearing
    /// again, a finished video) the first page is merged into the loaded cards, so later
    /// pages and the focused card stay.
    private func reload() async {
        let kind = kind
        let sort = sort.wrappedValue
        await list.reload(using: appState, key: sort) { client, offset, limit in
            try await client.items(kind: kind, sort: sort, limit: limit, offset: offset)
        }
    }

    private var sort: Binding<ItemSort> {
        Binding(
            get: { ItemSort(rawValue: storedSort) ?? .recent },
            set: { storedSort = $0.rawValue }
        )
    }

    /// Six posters spread over the content width, so the grid's right edge lines up with
    /// the sort pill's and both page margins are equal.
    private static let columnCount = 6
    private let columns = Array(
        repeating: GridItem(
            .fixed(Theme.Layout.gridPosterWidth),
            spacing: (Theme.Layout.contentWidth - Theme.Layout.gridPosterWidth * CGFloat(columnCount)) / CGFloat(columnCount - 1),
            alignment: .top
        ),
        count: columnCount
    )

    /// Room above the first row for a focused poster's lift, inside the grid's clip.
    private static let liftInset: CGFloat = 40

    var body: some View {
        // The title and sort pill stay put; the grid scrolls below them and never under
        // them or the sidebar's chip.
        VStack(alignment: .leading, spacing: 40 - Self.liftInset) {
            header
                .padding(.horizontal, Theme.Layout.margin)
            ScrollView(.vertical, showsIndicators: false) {
                content
                    .padding(.horizontal, Theme.Layout.margin)
                    .padding(.top, Self.liftInset)
                    .padding(.bottom, 100)
            }
            .reportsTabScroll()
            // Lifted posters may reach past the sides and the bottom; at the top, rows
            // scrolled up fade out under the header instead of sliding over it.
            .scrollClipDisabled()
            .mask {
                VStack(spacing: 0) {
                    LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                        .frame(height: Self.liftInset)
                    Color.black
                }
                .padding(.horizontal, -Theme.Layout.margin)
                .padding(.bottom, -200)
            }
        }
        .ignoresSafeArea(edges: .horizontal)
        .background(Theme.Colors.background.ignoresSafeArea())
        .task(id: sort.wrappedValue) {
            await reload()
        }
        .onChange(of: playback.completedSessions) {
            Task { await reload() }
        }
        .onChange(of: appState.libraryRevision) {
            // Watched marks changed on a page.
            Task { await reload() }
        }
    }

    private var header: some View {
        PageHeader(title: title, count: list.total > 0 ? countText : "") {
            SegmentedPill(options: [
                SegmentedPill<ItemSort>.Option(value: .recent, title: String(localized: "Recently Added", bundle: .localized)),
                SegmentedPill<ItemSort>.Option(value: .title, title: String(localized: "By Title", bundle: .localized)),
                SegmentedPill<ItemSort>.Option(value: .year, title: String(localized: "By Year", bundle: .localized)),
            ], selection: sort)
        }
    }

    private var countText: String {
        kind == .series
            ? String(localized: "\(list.total) shows", bundle: .localized)
            : String(localized: "\(list.total) movies", bundle: .localized)
    }

    @ViewBuilder
    private var content: some View {
        switch list.state {
        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity, minHeight: 600)
        case .failed(let message):
            ErrorStateView(message: message) {
                Task { await reload() }
            }
            .frame(minHeight: 700)
        case .loaded:
            if list.items.isEmpty {
                EmptyStateView(
                    systemImage: kind == .series ? "tv" : "film",
                    title: kind == .series ? "No TV shows yet" : "No movies yet",
                    message: "Add them to the server's media folders and scan the library."
                )
                .frame(minHeight: 700)
            } else {
                grid
            }
        }
    }

    private var grid: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: Theme.Layout.gridRowSpacing) {
            ForEach(list.items, id: \.uniqueKey) { card in
                NavigationLink(value: Route.item(card)) {
                    PosterCard(card: card, width: Theme.Layout.gridPosterWidth)
                }
                .buttonStyle(CardButtonStyle())
                .playsOnPlayPause(card)
                .task { await list.loadMoreIfNeeded(after: card, using: appState) }
            }
        }
        .focusSection()
        .overlay(alignment: .bottom) {
            if list.isLoadingMore {
                ProgressView().offset(y: 80)
            }
        }
    }
}
