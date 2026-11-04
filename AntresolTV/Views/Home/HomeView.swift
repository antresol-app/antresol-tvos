import AntresolKit
import SwiftUI

/// The Home tab: hero, Continue Watching and every shelf from `/api/home`.
struct HomeView: View {
    @Environment(AppState.self) private var appState
    @Environment(PlaybackCoordinator.self) private var playback
    @Environment(AudioPlayer.self) private var audio
    @Environment(\.openRoute) private var openRoute
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
        .onChange(of: playback.completedSessions) {
            Task { await model.load(using: appState) }
        }
        .onChange(of: audio.progressRevision) {
            Task { await model.load(using: appState) }
        }
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
                    // Like the TV app's Up Next row: select resumes (asking first), long
                    // press offers the details page or a fresh start.
                    ShelfRow(title: shelf.title, items: shelf.cards, id: \.uniqueKey) { card in
                        Button {
                            playback.play(card, from: .ask)
                        } label: {
                            WideCard(card: card)
                        }
                        .buttonStyle(CardButtonStyle())
                        .contextMenu {
                            Button {
                                openRoute(.item(card))
                            } label: {
                                Label("Details", systemImage: "info.circle")
                            }
                            Button {
                                playback.play(card, from: .beginning)
                            } label: {
                                Label("Play from Beginning", systemImage: "arrow.counterclockwise")
                            }
                        }
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
