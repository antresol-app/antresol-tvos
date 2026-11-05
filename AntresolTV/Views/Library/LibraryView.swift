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

    private let columns = Array(
        repeating: GridItem(.fixed(Theme.Layout.gridPosterWidth), spacing: Theme.Layout.gridSpacing, alignment: .top),
        count: 6
    )

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 40) {
                header
                content
            }
            .padding(.horizontal, Theme.Layout.margin)
            .padding(.bottom, 100)
        }
        .scrollClipDisabled()
        .ignoresSafeArea(edges: .horizontal)
        .background(Theme.Colors.background.ignoresSafeArea())
        .task(id: sort.wrappedValue) {
            await model.reload(sort: sort.wrappedValue, using: appState)
        }
        .onChange(of: playback.completedSessions) {
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
