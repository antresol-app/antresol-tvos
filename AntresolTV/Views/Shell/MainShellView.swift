import AntresolKit
import SwiftUI

/// The signed-in app: native tvOS top tab bar with Search, the library sections and the
/// profile tab. Each tab keeps its own navigation stack.
struct MainShellView: View {
    let user: User

    @State private var selection: ShellTab = .home
    @State private var playback = PlaybackCoordinator()
    @State private var audio = AudioPlayer()
    @State private var showsNowPlaying = false
    @AppStorage("books.section") private var booksPane: BooksView.Pane = .home
    @Environment(AppState.self) private var appState

    var body: some View {
        TabView(selection: $selection) {
            TabNavigation {
                SearchView { tab, pane in
                    if let pane { booksPane = pane }
                    selection = tab
                }
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

            TabNavigation { MusicView() }
                .tabItem { Text("Music") }
                .tag(ShellTab.music)

            TabNavigation { BooksView(pane: $booksPane) }
                .tabItem { Text("Books") }
                .tag(ShellTab.books)

            if audio.hasContent {
                NowPlayingView(isInTab: true)
                    .tabItem {
                        Label("Now Playing", systemImage: audio.isPlaying ? "waveform" : "pause.fill")
                    }
                    .tag(ShellTab.nowPlaying)
            }

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
        .environment(audio)
        .fullScreenCover(item: presentedPlayback) { request in
            VideoPlayerView(request: request)
                .environment(appState)
                .environment(playback)
        }
        .background {
            // A second full-screen cover needs its own host view.
            Color.clear
                .fullScreenCover(isPresented: $showsNowPlaying) {
                    NowPlayingView()
                        .environment(appState)
                        .environment(audio)
                }
        }
        .onChange(of: audio.presentationRequests) {
            if selection != .nowPlaying { showsNowPlaying = true }
        }
        .onChange(of: audio.hasContent) { _, hasContent in
            if !hasContent {
                showsNowPlaying = false
                if selection == .nowPlaying { selection = .home }
            }
        }
        .onChange(of: playback.presented) { _, request in
            // Video takes over the audio session.
            if request != nil { audio.pause() }
        }
        .onPlayPauseCommand {
            if audio.hasContent { audio.togglePlayPause() }
        }
        .task {
            if let client = appState.client {
                audio.attach(to: appState, mediaKeys: playback.mediaKeyStore(for: client))
            }
        }
        .onDisappear { audio.stop() }
    }

    private var presentedPlayback: Binding<PlaybackCoordinator.Request?> {
        Binding(
            get: { playback.presented },
            set: { playback.presented = $0 }
        )
    }
}

enum ShellTab: Hashable {
    case search, home, movies, shows, music, books, nowPlaying, account
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
                    case .genre(let name):
                        GenreView(name: name)
                    }
                }
        }
        .environment(\.openRoute, OpenRouteAction { path.append($0) })
    }
}
