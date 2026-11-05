import AntresolKit
import SwiftUI
import TVServices

/// The signed-in app: native tvOS top tab bar with Search, the library sections and the
/// profile tab. Each tab keeps its own navigation stack.
struct MainShellView: View {
    let user: User

    @State private var selection: ShellTab = .home
    @State private var playback = PlaybackCoordinator()
    @State private var audio = AudioPlayer()
    @State private var showsNowPlaying = false
    @State private var homePath = NavigationPath()
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

            TabNavigation(path: $homePath) { HomeView() }
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
                        // Icon only, like Search: with a text label the eighth tab
                        // pushes the profile tab out of the bar.
                        Image(systemName: audio.isPlaying ? "waveform" : "pause.fill")
                            .accessibilityLabel(Text("Now Playing"))
                    }
                    .tag(ShellTab.nowPlaying)
            }

            SettingsView(user: user)
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
        .onChange(of: playback.completedSessions) {
            // Continue Watching changed.
            TVTopShelfContentProvider.topShelfContentDidChange()
        }
        .task(id: appState.pendingDeepLink) {
            await openPendingDeepLink()
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

    /// Opens a Top Shelf / URL-scheme link: the item's page on the Home tab, or playback.
    private func openPendingDeepLink() async {
        guard let link = appState.pendingDeepLink, let client = appState.client else { return }
        // Cleared only once handled: clearing it earlier would cancel this task.
        defer { appState.pendingDeepLink = nil }
        let card: Card
        do {
            card = try await client.item(id: link.itemId).card
        } catch {
            // A link to an item this profile cannot see (or a gone item) is ignored.
            _ = appState.message(for: error)
            return
        }
        showsNowPlaying = false
        if case .play = link, card.kind.isVideo, playback.presented == nil {
            playback.play(card, from: .resume)
            return
        }
        selection = .home
        var path = NavigationPath()
        path.append(Route.item(card))
        homePath = path
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

/// A tab's navigation stack with the app's routes registered. The stack's path is its
/// own unless the caller passes one (to open pages from outside, e.g. deep links).
struct TabNavigation<Root: View>: View {
    private let externalPath: Binding<NavigationPath>?
    private let root: () -> Root
    @State private var ownPath = NavigationPath()

    init(path: Binding<NavigationPath>? = nil, @ViewBuilder root: @escaping () -> Root) {
        externalPath = path
        self.root = root
    }

    private var path: Binding<NavigationPath> {
        externalPath ?? $ownPath
    }

    var body: some View {
        NavigationStack(path: path) {
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
        .environment(\.openRoute, OpenRouteAction { path.wrappedValue.append($0) })
    }
}
