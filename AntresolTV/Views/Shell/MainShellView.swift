import AntresolKit
import SwiftUI
import TVServices

/// The signed-in app: the system sidebar on tvOS 18 and later (the top tab bar before it)
/// with Search, the library sections, live TV, Now Playing and the profile. Each tab keeps its own
/// navigation stack; a tab left for five seconds goes back to its first state (`TabResetCoordinator`).
struct MainShellView: View {
    let user: User

    @State private var selection: ShellTab = .home
    @State private var playback = PlaybackCoordinator()
    @State private var audio = AudioPlayer()
    @State private var playlists = PlaylistActions()
    @State private var showsNowPlaying = false
    @State private var tabReset = TabResetCoordinator()
    /// The profile's avatar, drawn once for the profile tab.
    @State private var avatarImage: UIImage?
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
        .sheet(item: $playlists.addRequest) { request in
            AddToPlaylistView(request: request)
                .environment(appState)
                .environment(playlists)
        }
        .fullScreenCover(item: $playback.presented) { request in
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
        .background {
            Color.clear
                .fullScreenCover(item: $playback.presentedChannel) { request in
                    LivePlayerView(request: request)
                        .environment(appState)
                        .environment(playback)
                }
        }
        .background {
            Color.clear
                .fullScreenCover(item: $playback.presentedTrailer) { request in
                    TrailerPlayerView(request: request)
                        .environment(appState)
                }
        }
        .onChange(of: selection) { old, new in
            tabReset.selectionChanged(from: old, to: new)
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
        .onChange(of: playback.presentedChannel) { _, request in
            if request != nil { audio.pause() }
        }
        .onChange(of: playback.presentedTrailer) { _, request in
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
            Tab("Shows", systemImage: "tv", value: ShellTab.shows) {
                showsTab
            }
            Tab("TV", systemImage: "antenna.radiowaves.left.and.right", value: ShellTab.tv) {
                tvTab
            }
            Tab("Music", systemImage: "music.note", value: ShellTab.music) {
                musicTab
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
                .tabItem { Text("Shows") }
                .tag(ShellTab.shows)

            tvTab
                .tabItem { Text("TV") }
                .tag(ShellTab.tv)

            musicTab
                .tabItem { Text("Music") }
                .tag(ShellTab.music)

            if audio.hasContent {
                NowPlayingView(isInTab: true)
                    .tabItem {
                        // Icon only, like Search, so the bar keeps room for the
                        // profile tab.
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
        TabNavigation(tab: .search, reset: tabReset) {
            SearchView { selection = $0 }
        }
    }

    private var homeTab: some View {
        TabNavigation(tab: .home, reset: tabReset) { HomeView() }
    }

    private var moviesTab: some View {
        TabNavigation(tab: .movies, reset: tabReset) { LibraryView(kind: .movie, title: "Movies") }
    }

    private var showsTab: some View {
        TabNavigation(tab: .shows, reset: tabReset) { LibraryView(kind: .series, title: "Shows") }
    }

    private var tvTab: some View {
        TabNavigation(tab: .tv, reset: tabReset) { TVView() }
    }

    private var musicTab: some View {
        TabNavigation(tab: .music, reset: tabReset) { MusicView() }
    }

    private var accountTab: some View {
        SettingsView(user: user)
            .id(tabReset.generation(of: .account))
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

    /// Opens a Top Shelf / URL-scheme link: the item's page on the Home tab, playback
    /// (Home alone for a book), or a live channel's player over the TV tab.
    private func openPendingDeepLink() async {
        guard let link = appState.pendingDeepLink, let client = appState.client else { return }
        // Cleared only once handled: clearing it earlier would cancel this task.
        defer { appState.pendingDeepLink = nil }
        guard let itemId = link.itemId else {
            if case .channel(let id) = link { await openChannel(id, client: client) }
            return
        }
        let card: Card
        do {
            card = try await client.item(id: itemId).card
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
        // The app has no pages for books: a link to one just opens Home.
        if !card.kind.isBook { path.append(Route.linkedItem(card)) }
        tabReset.setPath(path, for: .home)
    }

    /// `antresol://channel/{id}`: the channel's live player, with the TV tab under it. A
    /// channel this profile does not see is ignored; a video already playing is left alone.
    private func openChannel(_ id: Int, client: APIClient) async {
        let channels: [Channel]
        do {
            channels = try await ChannelService(client: client).list().channels
        } catch {
            _ = appState.message(for: error)
            return
        }
        guard let channel = channels.first(where: { $0.id == id }), playback.presented == nil else { return }
        showsNowPlaying = false
        selection = .tv
        playback.watch(channel, channels: channels)
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
}

enum ShellTab: Hashable {
    case search, home, movies, shows, tv, music, nowPlaying, account
}

/// A tab's navigation stack with the app's routes registered. The shell's reset
/// coordinator keeps the path (so deep links can open pages and a reset can pop it) and
/// rebuilds the root when the tab is reset.
struct TabNavigation<Root: View>: View {
    let tab: ShellTab
    let reset: TabResetCoordinator
    @ViewBuilder let root: () -> Root

    var body: some View {
        let path = reset.path(for: tab)
        NavigationStack(path: path) {
            root()
                .id(reset.generation(of: tab))
                .navigationDestination(for: Route.self) { route in
                    Group {
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
                    .modifier(FullScreenWidth())
                }
        }
        .environment(\.openRoute, OpenRouteAction { path.wrappedValue.append($0) })
        .environment(\.shellTab, tab)
        .environment(\.tabReset, reset)
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

/// Lays a pushed page out from the screen's left edge. On tvOS 27 the sidebar places
/// pages pushed in the Movies and TV Shows tabs in a frame that starts 139 pt in (a black
/// band down the left; Home's and Music's pushes are full width), and no safe-area
/// setting reaches that frame. The page measures where it was put and takes the screen's
/// width back; where it starts at the edge nothing changes.
private struct FullScreenWidth: ViewModifier {
    func body(content: Content) -> some View {
        GeometryReader { geo in
            let lead = max(0, geo.frame(in: .global).minX)
            content
                .frame(width: geo.size.width + lead, height: geo.size.height)
                .position(x: (geo.size.width + lead) / 2 - lead, y: geo.size.height / 2)
        }
        .ignoresSafeArea()
    }
}
