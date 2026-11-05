import AntresolKit
import SwiftUI

/// The Books tab: a page title and section pill — Reading Now (the server's book shelves),
/// Audiobooks, Manga & Comics and Books — with a sort pill on the lists.
struct BooksView: View {
    enum Pane: String, CaseIterable, Hashable {
        case home, audiobooks, comics, books

        var title: String {
            switch self {
            case .home: return String(localized: "Reading Now", bundle: .localized)
            case .audiobooks: return String(localized: "Audiobooks", bundle: .localized)
            case .comics: return String(localized: "Manga & Comics", bundle: .localized)
            case .books: return String(localized: "Books", bundle: .localized)
            }
        }

        var listKind: BookListKind? {
            switch self {
            case .home: return nil
            case .audiobooks: return .audiobook
            case .comics: return .comic
            case .books: return .book
            }
        }
    }

    @Binding var pane: Pane

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 40) {
                PageHeader(title: "Books") {
                    SegmentedPill(options: Pane.allCases.map { SegmentedPill<Pane>.Option(value: $0, title: $0.title) }, selection: $pane)
                }
                .padding(.horizontal, Theme.Layout.margin)

                if let kind = pane.listKind {
                    BookListSection(kind: kind)
                        .id(kind)
                } else {
                    BooksHomeSection()
                }
            }
            .padding(.bottom, 100)
        }
        .scrollClipDisabled()
        .ignoresSafeArea(edges: .horizontal)
        .background(Theme.Colors.background.ignoresSafeArea())
    }
}

private struct BooksHomeSection: View {
    @Environment(AppState.self) private var appState
    @Environment(AudioPlayer.self) private var audio
    @State private var loader = ContentLoader<[Shelf]>()

    var body: some View {
        Group {
            switch loader.state {
            case .loading:
                ProgressView().frame(maxWidth: .infinity, minHeight: 400)
            case .failed(let message):
                ErrorStateView(message: message) { Task { await load() } }
                    .frame(minHeight: 600)
            case .loaded(let shelves):
                if shelves.isEmpty {
                    EmptyStateView(systemImage: "books.vertical", title: "No books yet", message: "Add audiobooks, comics and books to the server's media folders and scan the library.")
                        .frame(minHeight: 500)
                } else {
                    LazyVStack(alignment: .leading, spacing: Theme.Layout.shelfSpacing) {
                        ForEach(shelves) { shelf in
                            ShelfRow(title: shelf.title, items: shelf.cards, id: \.uniqueKey) { card in
                                NavigationLink(value: Route.item(card)) {
                                    PosterCard(card: card)
                                }
                                .buttonStyle(CardButtonStyle())
                            }
                        }
                    }
                }
            }
        }
        .task { await load() }
        .onChange(of: audio.progressRevision) { Task { await load() } }
    }

    private func load() async {
        await loader.load(using: appState) { client in
            try await client.booksHome().shelves.filter { !$0.cards.isEmpty }
        }
    }
}

private struct BookListSection: View {
    let kind: BookListKind

    @Environment(AppState.self) private var appState
    @AppStorage private var sort: BookSort
    @State private var list = PagedList<Card>(key: \.uniqueKey)

    init(kind: BookListKind) {
        self.kind = kind
        _sort = AppStorage(wrappedValue: .added, "books.sort.\(kind.rawValue)")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 40) {
            HStack {
                if list.total > 0 {
                    Text(verbatim: countText)
                        .font(Theme.Typography.meta)
                        .foregroundStyle(Theme.Colors.label3)
                }
                Spacer()
                SegmentedPill(options: [
                    SegmentedPill<BookSort>.Option(value: .added, title: String(localized: "Recently Added", bundle: .localized)),
                    SegmentedPill<BookSort>.Option(value: .title, title: String(localized: "By Title", bundle: .localized)),
                    SegmentedPill<BookSort>.Option(value: .author, title: String(localized: "By Author", bundle: .localized)),
                ], selection: $sort)
            }
            .padding(.horizontal, Theme.Layout.margin)
            // Full width, so Up from any grid column reaches the sort pill.
            .focusSection()
            CardGrid(
                list: list,
                shape: kind == .audiobook ? .square : .poster,
                emptyIcon: kind == .audiobook ? "headphones" : "books.vertical",
                emptyTitle: kind == .audiobook ? "No audiobooks yet" : (kind == .comic ? "No comics yet" : "No books yet")
            )
        }
        .task(id: sort) {
            let sort = sort
            let kind = kind
            await list.reload(using: appState, key: sort) { client, offset, limit in
                try await client.books(kind: kind, sort: sort, limit: limit, offset: offset)
            }
        }
    }

    private var countText: String {
        switch kind {
        case .audiobook: return String(localized: "\(list.total) audiobooks", bundle: .localized)
        case .comic: return String(localized: "\(list.total) series", bundle: .localized)
        case .book: return String(localized: "\(list.total) books", bundle: .localized)
        }
    }
}
