import AntresolKit
import SwiftUI

/// The Home tab: hero, Continue Watching and every shelf from `/api/home`.
struct HomeView: View {
    @Environment(AppState.self) private var appState
    @State private var model = HomeModel()

    var body: some View {
        Group {
            switch model.state {
            case .loading:
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let message):
                ErrorStateView(message: message) {
                    Task { await model.load(using: appState) }
                }
            case .loaded(let content):
                if content.isEmpty {
                    EmptyStateView(
                        systemImage: "sparkles.tv",
                        title: "Your library is empty",
                        message: "Add movies, shows, music or books to the server's media folders and they will appear here."
                    )
                } else {
                    shelves(content)
                }
            }
        }
        .background(Theme.Colors.background.ignoresSafeArea())
        .task { await model.load(using: appState) }
    }

    private func shelves(_ content: HomeContent) -> some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(alignment: .leading, spacing: Theme.Layout.shelfSpacing) {
                if let feature = content.feature {
                    HeroView(card: feature.card, eyebrow: feature.eyebrow)
                } else {
                    Color.clear.frame(height: 140)
                }

                if let shelf = content.continueWatching {
                    ShelfRow(title: shelf.title, items: shelf.cards, id: \.uniqueKey) { card in
                        NavigationLink(value: Route.item(card)) {
                            WideCard(card: card)
                        }
                        .buttonStyle(CardButtonStyle())
                    }
                }

                ForEach(content.shelves) { shelf in
                    ShelfRow(title: shelf.title, items: shelf.cards, id: \.uniqueKey) { card in
                        NavigationLink(value: Route.item(card)) {
                            PosterCard(card: card)
                        }
                        .buttonStyle(CardButtonStyle())
                    }
                }
            }
            .padding(.bottom, 100)
        }
        .ignoresSafeArea(edges: [.top, .horizontal])
    }
}
