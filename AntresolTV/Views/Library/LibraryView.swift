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
    @State private var model: LibraryModel

    init(kind: ItemKind, title: LocalizedStringKey) {
        self.kind = kind
        self.title = title
        let key = "library.sort.\(kind.rawValue)"
        _storedSort = AppStorage(wrappedValue: ItemSort.recent.rawValue, key)
        let saved = UserDefaults.standard.string(forKey: key).flatMap(ItemSort.init(rawValue:)) ?? .recent
        _model = State(initialValue: LibraryModel(kind: kind, sort: saved))
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
            await model.reload(sort: sort.wrappedValue, using: appState)
        }
        .onChange(of: playback.completedSessions) {
            Task { await model.reload(sort: sort.wrappedValue, using: appState) }
        }
        .onChange(of: appState.libraryRevision) {
            // Watched marks changed on a page.
            Task { await model.reload(sort: sort.wrappedValue, using: appState) }
        }
    }

    private var header: some View {
        PageHeader(title: title, count: model.total > 0 ? countText : "") {
            SegmentedPill(options: [
                SegmentedPill<ItemSort>.Option(value: .recent, title: String(localized: "Recently Added", bundle: .localized)),
                SegmentedPill<ItemSort>.Option(value: .title, title: String(localized: "By Title", bundle: .localized)),
                SegmentedPill<ItemSort>.Option(value: .year, title: String(localized: "By Year", bundle: .localized)),
            ], selection: sort)
        }
    }

    private var countText: String {
        kind == .series
            ? String(localized: "\(model.total) shows", bundle: .localized)
            : String(localized: "\(model.total) movies", bundle: .localized)
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity, minHeight: 600)
        case .failed(let message):
            ErrorStateView(message: message) {
                Task { await model.reload(sort: sort.wrappedValue, using: appState) }
            }
            .frame(minHeight: 700)
        case .loaded:
            if model.cards.isEmpty {
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
            ForEach(model.cards, id: \.uniqueKey) { card in
                NavigationLink(value: Route.item(card)) {
                    PosterCard(card: card, width: Theme.Layout.gridPosterWidth)
                }
                .buttonStyle(CardButtonStyle())
                .playsOnPlayPause(card)
                .task { await model.loadMoreIfNeeded(after: card, using: appState) }
            }
        }
        .focusSection()
        .overlay(alignment: .bottom) {
            if model.isLoadingMore {
                ProgressView().offset(y: 80)
            }
        }
    }
}
