import AntresolKit
import SwiftUI

/// The signed-in app: native tvOS top tab bar with Search, the library sections and the
/// profile tab. Each tab keeps its own navigation stack.
struct MainShellView: View {
    let user: User

    @State private var selection: ShellTab = .home
    @State private var playback = PlaybackCoordinator()
    @Environment(AppState.self) private var appState

    var body: some View {
        TabView(selection: $selection) {
            TabNavigation {
                SearchView { selection = $0 }
            }
            .tabItem {
                Image(systemName: "magnifyingglass")
                    .accessibilityLabel(Text("Search"))
            }
            .tag(ShellTab.search)

            TabNavigation { HomeView() }
                .tabItem { Text("Home") }
                .tag(ShellTab.home)

            TabNavigation { LibraryView(kind: .movie, title: "Movies") }
                .tabItem { Text("Movies") }
                .tag(ShellTab.movies)

            TabNavigation { LibraryView(kind: .series, title: "TV Shows") }
                .tabItem { Text("TV Shows") }
                .tag(ShellTab.shows)

            SectionPlaceholderView(title: "Music", systemImage: "music.note")
                .tabItem { Text("Music") }
                .tag(ShellTab.music)

            SectionPlaceholderView(title: "Books", systemImage: "books.vertical")
                .tabItem { Text("Books") }
                .tag(ShellTab.books)

            AccountView(user: user)
                .tabItem {
                    Label {
                        Text(verbatim: user.name)
                    } icon: {
                        Image(systemName: "person.crop.circle")
                    }
                }
                .tag(ShellTab.account)
        }
        .environment(playback)
        .fullScreenCover(item: presentedPlayback) { request in
            VideoPlayerView(request: request)
                .environment(appState)
                .environment(playback)
        }
    }

    private var presentedPlayback: Binding<PlaybackCoordinator.Request?> {
        Binding(
            get: { playback.presented },
            set: { playback.presented = $0 }
        )
    }
}

enum ShellTab: Hashable {
    case search, home, movies, shows, music, books, account
}

/// A tab's navigation stack with the app's routes registered.
struct TabNavigation<Root: View>: View {
    @ViewBuilder let root: () -> Root
    @State private var path = NavigationPath()

    var body: some View {
        NavigationStack(path: $path) {
            root()
                .navigationDestination(for: Route.self) { route in
                    switch route {
                    case .item(let card):
                        ItemDetailView(card: card)
                    }
                }
        }
        .environment(\.openRoute, OpenRouteAction { path.append($0) })
    }
}

/// A library section that is not built yet (see NOTES.md, known gaps).
struct SectionPlaceholderView: View {
    let title: LocalizedStringKey
    let systemImage: String

    var body: some View {
        VStack(spacing: 32) {
            Image(systemName: systemImage)
                .font(.system(size: 96, weight: .regular))
                .foregroundStyle(Theme.Colors.label3)
            Text(title)
                .font(Theme.Typography.pageTitle)
                .foregroundStyle(Theme.Colors.label)
            Text("This section is coming soon.")
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Colors.label2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
