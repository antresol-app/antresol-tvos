import AntresolKit
import SwiftUI
import TVServices

/// The signed-in app: the system sidebar on tvOS 18 and later (the top tab bar before it)
/// with Search, the library sections, Now Playing and the profile. Each tab keeps its own
/// navigation stack.
struct MainShellView: View {
    let user: User

    @State private var selection: ShellTab = .home
    @State private var playback = PlaybackCoordinator()
    @State private var audio = AudioPlayer()
    @State private var playlists = PlaylistActions()
    @State private var showsNowPlaying = false
    @State private var homePath = NavigationPath()
    /// The profile's avatar, drawn once for the profile tab.
    @State private var avatarImage: UIImage?
    @AppStorage("books.section") private var booksPane: BooksView.Pane = .home
    @Environment(AppState.self) private var appState

    var body: some View {
        tabs
        .environment(playback)
        .environment(audio)
        .environment(playlists)
        .overlay(alignment: .bottom) {
            if let message = bannerMessage {
                NoticeBanner(message: message)
                    .padding(.bottom, 50)
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }
        }
        .animation(Theme.Motion.easeOut, value: bannerMessage)
        .sheet(item: addToPlaylistRequest) { request in
            AddToPlaylistView(request: request)
                .environment(appState)
                .environment(playlists)
        }
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
            appState.prepareToLeaveProfile = { [audio] in
                await audio.stopAndFlush()
            }
            avatarImage = renderAvatar()
        }
        .onDisappear { audio.shutdown() }
    }

    /// tvOS 18 and later: the system sidebar (`sidebarAdaptable`), a glass panel on the left
    /// that collapses to a chip naming the current section, as in the TV and Music apps.
    /// Before it: the top tab bar.
    @ViewBuilder
    private var tabs: some View {
        if #available(tvOS 18.0, *) {
            sidebarTabs
        } else {
            topTabs
        }
    }

    @available(tvOS 18.0, *)
    private var sidebarTabs: some View {
        TabView(selection: $selection) {
            Tab("Search", systemImage: "magnifyingglass", value: ShellTab.search, role: .search) {
                searchTab
            }
            Tab("Home", systemImage: "house", value: ShellTab.home) {
                homeTab
            }
            Tab("Movies", systemImage: "film", value: ShellTab.movies) {
                moviesTab
            }
            Tab("TV Shows", systemImage: "tv", value: ShellTab.shows) {
                showsTab
            }
            Tab("Music", systemImage: "music.note", value: ShellTab.music) {
                musicTab
            }
            Tab("Books", systemImage: "books.vertical", value: ShellTab.books) {
                booksTab
            }
            if audio.hasContent {
                Tab("Now Playing", systemImage: audio.isPlaying ? "waveform" : "pause.fill", value: ShellTab.nowPlaying) {
                    NowPlayingView(isInTab: true)
                }
            }
            Tab(value: ShellTab.account) {
                accountTab
            } label: {
                profileLabel
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        .modifier(SidebarProfileHeader(user: user))
    }

    private var topTabs: some View {
        TabView(selection: $selection) {
            searchTab
                .tabItem {
                    Image(systemName: "magnifyingglass")
                        .accessibilityLabel(Text("Search"))
                }
                .tag(ShellTab.search)

            homeTab
                .tabItem { Text("Home") }
                .tag(ShellTab.home)

            moviesTab
                .tabItem { Text("Movies") }
                .tag(ShellTab.movies)

            showsTab
                .tabItem { Text("TV Shows") }
                .tag(ShellTab.shows)

            musicTab
                .tabItem { Text("Music") }
                .tag(ShellTab.music)

            booksTab
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

            accountTab
                .tabItem { profileLabel }
                .tag(ShellTab.account)
        }
    }

    private var searchTab: some View {
        TabNavigation {
            SearchView { tab, pane in
                if let pane { booksPane = pane }
                selection = tab
            }
        }
    }

    private var homeTab: some View {
        TabNavigation(path: $homePath) { HomeView() }
    }

    private var moviesTab: some View {
        TabNavigation { LibraryView(kind: .movie, title: "Movies") }
    }

    private var showsTab: some View {
        TabNavigation { LibraryView(kind: .series, title: "TV Shows") }
    }

    private var musicTab: some View {
        TabNavigation { MusicView() }
    }

    private var booksTab: some View {
        TabNavigation { BooksView(pane: $booksPane) }
    }

    private var accountTab: some View {
        SettingsView(user: user)
    }

    /// The profile's name and avatar: the account tab's label.
    private var profileLabel: some View {
        Label {
            Text(verbatim: user.name)
        } icon: {
            if let avatarImage {
                // Original rendering: a template image would turn into a plain disc.
                Image(uiImage: avatarImage)
                    .renderingMode(.original)
            } else {
                Image(systemName: "person.crop.circle")
            }
        }
        .accessibilityLabel(Text(verbatim: String(localized: "\(user.name), Profile and Settings", bundle: .localized)))
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
        path.append(Route.linkedItem(card))
        homePath = path
    }

    /// The avatar circle (grad-N gradient and initial) as an image that keeps its colours
    /// in the tab bar.
    private func renderAvatar() -> UIImage? {
        let renderer = ImageRenderer(content: AvatarView(user: user, size: 40))
        renderer.scale = 2
        return renderer.uiImage?.withRenderingMode(.alwaysOriginal)
    }

    /// Playlist confirmations, and the music player's "Playing next" / "Added to queue"
    /// (Now Playing shows those itself).
    private var bannerMessage: String? {
        playlists.message ?? appState.notice ?? (selection == .nowPlaying ? nil : audio.notice)
    }

    private var addToPlaylistRequest: Binding<PlaylistActions.AddRequest?> {
        Binding(
            get: { playlists.addRequest },
            set: { playlists.addRequest = $0 }
        )
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
                    case .linkedItem(let card):
                        ItemDetailView(card: card)
                            .environment(\.claimsFocusOnAppear, true)
                    case .genre(let name):
                        GenreView(name: name)
                    case .shelf(let id, let title):
                        ShelfGridView(shelfId: id, title: title)
                    }
                }
        }
        .environment(\.openRoute, OpenRouteAction { path.wrappedValue.append($0) })
    }
}

/// The sidebar's header on tvOS 27 and later: the profile's avatar and name with the time,
/// like the TV app. Earlier systems have no sidebar header; the account tab shows the
/// profile there.
private struct SidebarProfileHeader: ViewModifier {
    let user: User

    func body(content: Content) -> some View {
        if #available(tvOS 27.0, *) {
            content.tabViewSidebarHeader {
                HStack(spacing: 16) {
                    AvatarView(user: user, size: 52)
                    Text(verbatim: user.name)
                        .font(Theme.Typography.headline)
                        .lineLimit(1)
                    Spacer(minLength: 12)
                    TimelineView(.everyMinute) { context in
                        Text(context.date, style: .time)
                            .font(Theme.Typography.cardMeta)
                            .foregroundStyle(Theme.Colors.label2)
                    }
                }
                .padding(.vertical, 8)
            }
        } else {
            content
        }
    }
}
