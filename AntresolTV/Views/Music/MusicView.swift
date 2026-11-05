import AntresolKit
import SwiftUI

/// The Music tab: a page title and section pill — Listen Now (the server's music shelves
/// and Shuffle All), Albums, Artists, Songs, Genres and Playlists.
struct MusicView: View {
    enum Pane: String, CaseIterable, Hashable {
        case listenNow, albums, artists, songs, genres, playlists

        var title: String {
            switch self {
            case .listenNow: return String(localized: "Listen Now", bundle: .localized)
            case .albums: return String(localized: "Albums", bundle: .localized)
            case .artists: return String(localized: "Artists", bundle: .localized)
            case .songs: return String(localized: "Songs", bundle: .localized)
            case .genres: return String(localized: "Genres", bundle: .localized)
            case .playlists: return String(localized: "Playlists", bundle: .localized)
            }
        }
    }

    @AppStorage("music.section") private var section: Pane = .listenNow

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 40) {
                PageHeader(title: "Music") {
                    SegmentedPill(options: Pane.allCases.map { SegmentedPill<Pane>.Option(value: $0, title: $0.title) }, selection: $section)
                }
                .padding(.horizontal, Theme.Layout.margin)

                switch section {
                case .listenNow: MusicHomeSection()
                case .albums: AlbumsSection()
                case .artists: ArtistsSection()
                case .songs: SongsSection()
                case .genres: GenresSection()
                case .playlists: PlaylistsSection()
                }
            }
            .padding(.bottom, 100)
        }
        .scrollClipDisabled()
        .ignoresSafeArea(edges: .horizontal)
        .background(Theme.Colors.background.ignoresSafeArea())
    }
}

/// A tab's large title with a control (section or sort pill) on the right.
struct PageHeader<Accessory: View>: View {
    let title: LocalizedStringKey
    var count: String = ""
    @ViewBuilder let accessory: () -> Accessory

    var body: some View {
        HStack(alignment: .center) {
            Text(title)
                .font(Theme.Typography.pageTitle)
                .foregroundStyle(Theme.Colors.label)
                .accessibilityAddTraits(.isHeader)
            if !count.isEmpty {
                Text(verbatim: count)
                    .font(Theme.Typography.meta)
                    .foregroundStyle(Theme.Colors.label3)
                    .padding(.leading, 20)
                    .padding(.top, 14)
            }
            Spacer(minLength: 40)
            accessory()
        }
        // The pill sits top right: moving up from the left edge of the page should
        // still reach it rather than skip to the tab bar.
        .focusSection()
    }
}

// MARK: - Listen Now

private struct MusicHomeSection: View {
    @Environment(AppState.self) private var appState
    @Environment(AudioPlayer.self) private var audio
    @State private var loader = ContentLoader<[Shelf]>()
    @State private var shuffleError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Layout.shelfSpacing) {
            HStack(spacing: 24) {
                Button {
                    Task { await shuffleAll() }
                } label: {
                    Label("Shuffle All", systemImage: "shuffle")
                }
                .buttonStyle(PillButtonStyle(kind: .primary))
                if let shuffleError {
                    Text(verbatim: shuffleError)
                        .font(Theme.Typography.meta)
                        .foregroundStyle(Theme.Colors.red)
                }
            }
            .padding(.horizontal, Theme.Layout.margin)
            .focusSection()

            switch loader.state {
            case .loading:
                ProgressView().frame(maxWidth: .infinity, minHeight: 400)
            case .failed(let message):
                ErrorStateView(message: message) { Task { await load() } }
                    .frame(minHeight: 600)
            case .loaded(let shelves):
                if shelves.isEmpty {
                    EmptyStateView(systemImage: "music.note", title: "No music yet", message: "Add albums to the server's music folder and scan the library.")
                        .frame(minHeight: 500)
                } else {
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
        .task { await load() }
    }

    private func load() async {
        await loader.load(using: appState) { client in
            try await client.musicHome().shelves.filter { !$0.cards.isEmpty }
        }
    }

    private func shuffleAll() async {
        guard let client = appState.client else { return }
        shuffleError = nil
        do {
            let tracks = try await client.shuffle(.all)
            if tracks.isEmpty {
                shuffleError = String(localized: "There are no songs to play.", bundle: .localized)
            } else {
                audio.play(tracks: tracks)
            }
        } catch {
            shuffleError = appState.message(for: error)
        }
    }
}

// MARK: - Albums

private struct AlbumsSection: View {
    @Environment(AppState.self) private var appState
    @AppStorage("music.albumSort") private var sort: AlbumSort = .added
    @State private var list = PagedList<Card>(key: \.uniqueKey)

    var body: some View {
        VStack(alignment: .leading, spacing: 40) {
            HStack {
                Spacer()
                SegmentedPill(options: [
                    SegmentedPill<AlbumSort>.Option(value: .added, title: String(localized: "Recently Added", bundle: .localized)),
                    SegmentedPill<AlbumSort>.Option(value: .title, title: String(localized: "By Title", bundle: .localized)),
                    SegmentedPill<AlbumSort>.Option(value: .artist, title: String(localized: "By Artist", bundle: .localized)),
                    SegmentedPill<AlbumSort>.Option(value: .year, title: String(localized: "By Year", bundle: .localized)),
                    SegmentedPill<AlbumSort>.Option(value: .recent, title: String(localized: "Recently Played", bundle: .localized)),
                ], selection: $sort)
            }
            .padding(.horizontal, Theme.Layout.margin)
            CardGrid(list: list, shape: .square, emptyIcon: "square.stack", emptyTitle: "No albums yet")
        }
        .task(id: sort) {
            let sort = sort
            await list.reload(using: appState, reset: true) { client, offset, limit in
                try await client.albums(sort: sort, limit: limit, offset: offset)
            }
        }
    }
}

// MARK: - Artists

private struct ArtistsSection: View {
    @Environment(AppState.self) private var appState
    @State private var list = PagedList<Card>(key: \.uniqueKey)

    var body: some View {
        CardGrid(list: list, shape: .circle, emptyIcon: "music.mic", emptyTitle: "No artists yet")
            .task {
                await list.reload(using: appState) { client, offset, limit in
                    try await client.artists(limit: limit, offset: offset)
                }
            }
    }
}

/// A paged grid of cards: six 2:3 posters or artists per row, or five square covers.
struct CardGrid: View {
    let list: PagedList<Card>
    let shape: ArtworkShape
    let emptyIcon: String
    let emptyTitle: LocalizedStringKey

    @Environment(AppState.self) private var appState

    private var columnCount: Int { shape == .square ? 5 : 6 }

    private var cellWidth: CGFloat {
        shape == .square ? Theme.Layout.gridSquareWidth : Theme.Layout.gridPosterWidth
    }

    private var spacing: CGFloat {
        (Theme.Layout.contentWidth - cellWidth * CGFloat(columnCount)) / CGFloat(columnCount - 1)
    }

    var body: some View {
        switch list.state {
        case .loading:
            ProgressView().frame(maxWidth: .infinity, minHeight: 500)
        case .failed(let message):
            ErrorStateView(message: message) { Task { await list.reloadSameFetch(using: appState) } }
                .frame(minHeight: 600)
        case .loaded:
            if list.items.isEmpty {
                EmptyStateView(systemImage: emptyIcon, title: emptyTitle, message: "Add them to the server's media folders and scan the library.")
                    .frame(minHeight: 500)
            } else {
                LazyVGrid(
                    columns: Array(repeating: GridItem(.fixed(cellWidth), spacing: spacing, alignment: .top), count: columnCount),
                    alignment: .leading,
                    spacing: Theme.Layout.gridRowSpacing
                ) {
                    ForEach(list.items, id: \.uniqueKey) { card in
                        NavigationLink(value: Route.item(card)) {
                            PosterCard(card: card, shape: shape, width: cellWidth)
                        }
                        .buttonStyle(CardButtonStyle())
                        .task { await list.loadMoreIfNeeded(after: card, using: appState) }
                    }
                }
                .padding(.horizontal, Theme.Layout.margin)
                .focusSection()
            }
        }
    }
}

// MARK: - Songs

private struct SongsSection: View {
    @Environment(AppState.self) private var appState
    @Environment(AudioPlayer.self) private var audio
    @AppStorage("music.songsFavorites") private var favoritesOnly = false
    @State private var list = PagedList<Track>(pageSize: 120) { "\($0.id)" }

    var body: some View {
        VStack(alignment: .leading, spacing: 32) {
            HStack(spacing: 24) {
                Button {
                    audio.play(tracks: list.items, startAt: nil, shuffled: true)
                } label: {
                    Label("Shuffle", systemImage: "shuffle")
                }
                .buttonStyle(PillButtonStyle(kind: .primary))
                .disabled(list.items.isEmpty)
                Spacer()
                SegmentedPill(options: [
                    SegmentedPill<Bool>.Option(value: false, title: String(localized: "All Songs", bundle: .localized)),
                    SegmentedPill<Bool>.Option(value: true, title: String(localized: "Favorites", bundle: .localized)),
                ], selection: $favoritesOnly)
            }
            .focusSection()

            switch list.state {
            case .loading:
                ProgressView().frame(maxWidth: .infinity, minHeight: 400)
            case .failed(let message):
                ErrorStateView(message: message) { Task { await list.reloadSameFetch(using: appState) } }
                    .frame(minHeight: 600)
            case .loaded:
                if list.items.isEmpty {
                    EmptyStateView(
                        systemImage: favoritesOnly ? "star" : "music.note",
                        title: favoritesOnly ? "No favorite songs" : "No songs yet",
                        message: favoritesOnly ? "Long-press a song and choose Add to Favorites." : "Add albums to the server's music folder and scan the library."
                    )
                    .frame(minHeight: 500)
                } else {
                    LazyVStack(spacing: 4) {
                        ForEach(Array(list.items.enumerated()), id: \.element.id) { index, track in
                            TrackRow(track: track, leading: .cover, showsArtist: true) {
                                audio.play(tracks: list.items, startAt: index)
                            }
                            .task { await list.loadMoreIfNeeded(after: track, threshold: 30, using: appState) }
                        }
                    }
                    .focusSection()
                }
            }
        }
        .padding(.horizontal, Theme.Layout.margin)
        .task(id: favoritesOnly) {
            let starred = favoritesOnly
            await list.reload(using: appState, reset: true) { client, offset, limit in
                try await client.songs(starred: starred, limit: limit, offset: offset)
            }
        }
    }
}

// MARK: - Genres

private struct GenresSection: View {
    @Environment(AppState.self) private var appState
    @State private var loader = ContentLoader<[Genre]>()

    private let columns = Array(repeating: GridItem(.fixed(410), spacing: 40, alignment: .top), count: 4)

    var body: some View {
        Group {
            switch loader.state {
            case .loading:
                ProgressView().frame(maxWidth: .infinity, minHeight: 400)
            case .failed(let message):
                ErrorStateView(message: message) { Task { await load() } }
                    .frame(minHeight: 600)
            case .loaded(let genres):
                if genres.isEmpty {
                    EmptyStateView(systemImage: "guitars", title: "No genres yet", message: "Genres come from the tags of your music files.")
                        .frame(minHeight: 500)
                } else {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 40) {
                        ForEach(genres) { genre in
                            NavigationLink(value: Route.genre(genre.name)) {
                                GenreTile(genre: genre)
                            }
                            .buttonStyle(CardButtonStyle())
                        }
                    }
                    .padding(.horizontal, Theme.Layout.margin)
                    .focusSection()
                }
            }
        }
        .task { await load() }
    }

    private func load() async {
        await loader.load(using: appState) { try await $0.genres() }
    }
}

private struct GenreTile: View {
    let genre: Genre
    @Environment(\.isCardFocused) private var isFocused

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: genre.name)
                .font(Theme.Typography.headline)
                .foregroundStyle(.white)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
            Text(verbatim: metaLine([
                genre.albums > 0 ? String(localized: "\(genre.albums) albums", bundle: .localized) : "",
                genre.songs > 0 ? String(localized: "\(genre.songs) songs", bundle: .localized) : "",
            ]))
            .font(Theme.Typography.cardMeta)
            .foregroundStyle(.white.opacity(0.8))
        }
        .padding(28)
        .frame(width: 410, height: 180, alignment: .bottomLeading)
        .background(
            LinearGradient(
                colors: [Theme.tint(for: genre.name), Theme.tint(for: genre.name + "·").opacity(0.7)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
        )
        .cardLift(isFocused: isFocused)
    }
}

// MARK: - Playlists

private struct PlaylistsSection: View {
    @Environment(AppState.self) private var appState
    @State private var loader = ContentLoader<[Playlist]>()

    private let columns = Array(
        repeating: GridItem(.fixed(Theme.Layout.gridSquareWidth), spacing: Theme.Layout.gridSquareSpacing, alignment: .top),
        count: 5
    )

    var body: some View {
        Group {
            switch loader.state {
            case .loading:
                ProgressView().frame(maxWidth: .infinity, minHeight: 400)
            case .failed(let message):
                ErrorStateView(message: message) { Task { await load() } }
                    .frame(minHeight: 600)
            case .loaded(let playlists):
                if playlists.isEmpty {
                    EmptyStateView(systemImage: "music.note.list", title: "No playlists yet", message: "Create playlists in the Antresol web app; they appear here.")
                        .frame(minHeight: 500)
                } else {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: Theme.Layout.gridRowSpacing) {
                        ForEach(playlists) { playlist in
                            NavigationLink(value: Route.item(playlist.card)) {
                                PosterCard(card: playlist.card, shape: .square, width: Theme.Layout.gridSquareWidth)
                            }
                            .buttonStyle(CardButtonStyle())
                        }
                    }
                    .padding(.horizontal, Theme.Layout.margin)
                    .focusSection()
                }
            }
        }
        .task { await load() }
    }

    private func load() async {
        await loader.load(using: appState) { try await $0.playlists() }
    }
}

extension Playlist {
    /// The playlist as a card, for grids and the detail route.
    var card: Card {
        Card(
            id: id,
            kind: .playlist,
            title: name,
            subtitle: String(localized: "\(trackCount) songs", bundle: .localized),
            poster: cover.isEmpty ? (covers.first ?? "") : cover
        )
    }
}
