import AntresolKit
import SwiftUI

// MARK: - Album

/// An album: cover and tinted header with Play, Shuffle and Favorite, then the track
/// list (grouped by disc when there are several) and more by the artist.
struct AlbumDetailView: View {
    let card: Card

    @Environment(AppState.self) private var appState
    @Environment(AudioPlayer.self) private var audio
    @State private var loader = ContentLoader<AlbumDetail>()
    @State private var actionError: String?

    var body: some View {
        DetailScroll {
            let album = loader.value
            CollectionHeader(
                card: album?.card ?? card,
                eyebrow: ItemKind.album.displayName,
                subtitle: album?.artist?.name ?? card.subtitle,
                meta: album.map(Self.meta) ?? "",
                error: actionError
            ) {
                Button {
                    if let album { audio.play(tracks: album.tracks) }
                } label: {
                    Label("Play", systemImage: "play.fill")
                }
                .buttonStyle(PillButtonStyle(kind: .primary))
                .disabled(album?.tracks.isEmpty ?? true)

                Button {
                    if let album { audio.play(tracks: album.tracks, startAt: nil, shuffled: true) }
                } label: {
                    Label("Shuffle", systemImage: "shuffle")
                }
                .buttonStyle(PillButtonStyle(kind: .glass))
                .disabled(album?.tracks.isEmpty ?? true)

                if let album {
                    FavoriteButton(isStarred: album.starred) {
                        await toggleStar(album)
                    }
                    if let artist = album.artist, artist.id > 0 {
                        NavigationLink(value: Route.item(Card(id: artist.id, kind: .artist, title: artist.name, poster: album.card.poster))) {
                            Label("Go to Artist", systemImage: "music.mic")
                        }
                        .buttonStyle(PillButtonStyle(kind: .glass))
                    }
                }
            }

            switch loader.state {
            case .loading:
                ProgressView().frame(maxWidth: .infinity, minHeight: 200)
            case .failed(let message):
                ErrorStateView(message: message) { Task { await load() } }
                    .frame(minHeight: 500)
            case .loaded(let album):
                TrackList(tracks: album.tracks, groupsByDisc: true)
            }
        }
        .task(id: card.id) { await load() }
    }

    private func load() async {
        await loader.load(using: appState) { try await $0.album(id: card.id) }
    }

    private func toggleStar(_ album: AlbumDetail) async {
        guard let client = appState.client else { return }
        actionError = nil
        let starred = !album.starred
        loader.update { $0.starred = starred }
        do {
            try await client.setStarred(itemId: album.card.id, starred)
        } catch {
            loader.update { $0.starred = !starred }
            actionError = appState.message(for: error)
        }
    }

    private static func meta(_ album: AlbumDetail) -> String {
        metaLine([
            album.year > 0 ? String(album.year) : "",
            album.genres.prefix(2).joined(separator: ", "),
            album.trackCount > 0 ? String(localized: "\(album.trackCount) songs") : "",
            durationText(ms: album.durationMs),
            album.quality,
        ])
    }
}

/// The songs of an album or playlist; selecting one plays the list from there.
struct TrackList: View {
    let tracks: [Track]
    var groupsByDisc = false
    var leading: TrackRow.Leading = .number
    var showsArtist = false

    @Environment(AudioPlayer.self) private var audio

    private var discs: [Int] {
        Array(Set(tracks.map(\.discNo))).sorted()
    }

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 4) {
            if tracks.isEmpty {
                Text("No songs")
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Colors.label2)
            }
            ForEach(Array(tracks.enumerated()), id: \.offset) { index, track in
                if groupsByDisc, discs.count > 1, index == 0 || tracks[index - 1].discNo != track.discNo {
                    Text(verbatim: String(localized: "Disc \(track.discNo)"))
                        .font(Theme.Typography.eyebrow)
                        .tracking(2)
                        .textCase(.uppercase)
                        .foregroundStyle(Theme.Colors.label2)
                        .padding(.top, index == 0 ? 0 : 28)
                        .padding(.leading, 28)
                }
                TrackRow(track: track, leading: leading, showsArtist: showsArtist || track.artist != tracks.first?.artist) {
                    audio.play(tracks: tracks, startAt: index)
                }
            }
        }
        .padding(.horizontal, Theme.Layout.margin)
        .focusSection()
    }
}

/// A star toggle pill for albums and artists.
struct FavoriteButton: View {
    let isStarred: Bool
    let toggle: () async -> Void
    @State private var busy = false

    var body: some View {
        Button {
            busy = true
            Task {
                await toggle()
                busy = false
            }
        } label: {
            Label(isStarred ? "Favorite" : "Add to Favorites", systemImage: isStarred ? "star.fill" : "star")
        }
        .buttonStyle(PillButtonStyle(kind: .glass))
        .disabled(busy)
        .accessibilityValue(Text(isStarred ? LocalizedStringKey("In Favorites") : LocalizedStringKey("Not in Favorites")))
    }
}

/// The vertical page scaffold of detail pages: full-bleed header, then sections.
struct DetailScroll<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: Theme.Layout.shelfSpacing) {
                content()
            }
            .padding(.bottom, 100)
        }
        .scrollClipDisabled()
        .ignoresSafeArea(edges: [.top, .horizontal])
        .background(Theme.Colors.background.ignoresSafeArea())
    }
}

// MARK: - Artist

/// An artist: Play (top songs) and Shuffle (all of the artist's songs), top songs,
/// albums and the albums the artist appears on.
struct ArtistDetailView: View {
    let card: Card

    @Environment(AppState.self) private var appState
    @Environment(AudioPlayer.self) private var audio
    @State private var loader = ContentLoader<ArtistDetail>()
    @State private var isStarred: Bool?
    @State private var actionError: String?

    var body: some View {
        DetailScroll {
            let artist = loader.value
            CollectionHeader(
                card: artist?.card ?? card,
                eyebrow: ItemKind.artist.displayName,
                meta: artist.map(Self.meta) ?? "",
                error: actionError
            ) {
                Button {
                    if let artist { audio.play(tracks: artist.topTracks) }
                } label: {
                    Label("Play", systemImage: "play.fill")
                }
                .buttonStyle(PillButtonStyle(kind: .primary))
                .disabled(artist?.topTracks.isEmpty ?? true)

                Button {
                    Task { await shuffle() }
                } label: {
                    Label("Shuffle", systemImage: "shuffle")
                }
                .buttonStyle(PillButtonStyle(kind: .glass))

                if artist != nil {
                    FavoriteButton(isStarred: isStarred ?? false) {
                        await toggleStar()
                    }
                }
            }

            switch loader.state {
            case .loading:
                ProgressView().frame(maxWidth: .infinity, minHeight: 200)
            case .failed(let message):
                ErrorStateView(message: message) { Task { await load() } }
                    .frame(minHeight: 500)
            case .loaded(let artist):
                if !artist.topTracks.isEmpty {
                    VStack(alignment: .leading, spacing: 20) {
                        SectionTitle("Top Songs")
                        TrackList(tracks: Array(artist.topTracks.prefix(10)), leading: .cover, showsArtist: true)
                    }
                }
                if !artist.albums.isEmpty {
                    ShelfRow(title: String(localized: "Albums"), items: artist.albums, id: \.uniqueKey) { album in
                        NavigationLink(value: Route.item(album)) { PosterCard(card: album) }
                            .buttonStyle(CardButtonStyle())
                    }
                }
                if !artist.appearsOn.isEmpty {
                    ShelfRow(title: String(localized: "Appears On"), items: artist.appearsOn, id: \.uniqueKey) { album in
                        NavigationLink(value: Route.item(album)) { PosterCard(card: album) }
                            .buttonStyle(CardButtonStyle())
                    }
                }
            }
        }
        .task(id: card.id) { await load() }
    }

    private func load() async {
        await loader.load(using: appState) { try await $0.artist(id: card.id) }
        if isStarred == nil, let artist = loader.value {
            // The artist detail has no star flag; starred artists come from the list.
            isStarred = await starredArtistIds().contains(artist.card.id)
        }
    }

    private func starredArtistIds() async -> Set<Int> {
        guard let client = appState.client, let page = try? await client.artists(starred: true, limit: 500, offset: 0) else { return [] }
        return Set(page.items.map(\.id))
    }

    private func shuffle() async {
        guard let client = appState.client else { return }
        actionError = nil
        do {
            let tracks = try await client.shuffle(.artist(card.id))
            audio.play(tracks: tracks)
        } catch {
            actionError = appState.message(for: error)
        }
    }

    private func toggleStar() async {
        guard let client = appState.client else { return }
        let starred = !(isStarred ?? false)
        isStarred = starred
        actionError = nil
        do {
            try await client.setStarred(itemId: card.id, starred)
        } catch {
            isStarred = !starred
            actionError = appState.message(for: error)
        }
    }

    private static func meta(_ artist: ArtistDetail) -> String {
        metaLine([
            artist.albums.isEmpty ? "" : String(localized: "\(artist.albums.count) albums"),
            artist.card.subtitle,
        ])
    }
}

/// A section heading inside a page, aligned with the page margin.
struct SectionTitle: View {
    let title: LocalizedStringKey

    init(_ title: LocalizedStringKey) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .font(Theme.Typography.sectionTitle)
            .foregroundStyle(Theme.Colors.label)
            .padding(.horizontal, Theme.Layout.margin)
            .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - Playlist

/// A playlist: Play and Shuffle, then its songs.
struct PlaylistDetailView: View {
    let card: Card

    @Environment(AppState.self) private var appState
    @Environment(AudioPlayer.self) private var audio
    @State private var loader = ContentLoader<PlaylistDetail>()

    var body: some View {
        DetailScroll {
            let detail = loader.value
            CollectionHeader(
                card: detail?.playlist.card ?? card,
                eyebrow: ItemKind.playlist.displayName,
                meta: detail.map { metaLine([$0.playlist.card.subtitle, durationText(ms: $0.playlist.durationMs)]) } ?? card.subtitle
            ) {
                Button {
                    if let detail { audio.play(tracks: detail.tracks) }
                } label: {
                    Label("Play", systemImage: "play.fill")
                }
                .buttonStyle(PillButtonStyle(kind: .primary))
                .disabled(detail?.tracks.isEmpty ?? true)

                Button {
                    if let detail { audio.play(tracks: detail.tracks, startAt: nil, shuffled: true) }
                } label: {
                    Label("Shuffle", systemImage: "shuffle")
                }
                .buttonStyle(PillButtonStyle(kind: .glass))
                .disabled(detail?.tracks.isEmpty ?? true)
            }

            switch loader.state {
            case .loading:
                ProgressView().frame(maxWidth: .infinity, minHeight: 200)
            case .failed(let message):
                ErrorStateView(message: message) { Task { await load() } }
                    .frame(minHeight: 500)
            case .loaded(let detail):
                TrackList(tracks: detail.tracks, leading: .cover, showsArtist: true)
            }
        }
        .task(id: card.id) { await load() }
    }

    private func load() async {
        await loader.load(using: appState) { try await $0.playlist(id: card.id) }
    }
}

// MARK: - Genre

/// The albums of one genre, with a genre shuffle.
struct GenreView: View {
    let name: String

    @Environment(AppState.self) private var appState
    @Environment(AudioPlayer.self) private var audio
    @State private var list = PagedList<Card>(key: \.uniqueKey)
    @State private var actionError: String?

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 40) {
                VStack(alignment: .leading, spacing: 24) {
                    Text("Genre")
                        .font(Theme.Typography.eyebrow)
                        .tracking(2)
                        .textCase(.uppercase)
                        .foregroundStyle(Theme.Colors.label2)
                    Text(verbatim: name)
                        .font(Theme.Typography.pageTitle)
                        .foregroundStyle(Theme.Colors.label)
                    HStack(spacing: 24) {
                        Button {
                            Task { await shuffle() }
                        } label: {
                            Label("Shuffle", systemImage: "shuffle")
                        }
                        .buttonStyle(PillButtonStyle(kind: .primary))
                        if let actionError {
                            Text(verbatim: actionError)
                                .font(Theme.Typography.meta)
                                .foregroundStyle(Theme.Colors.red)
                        }
                    }
                    .focusSection()
                }
                .padding(.horizontal, Theme.Layout.margin)
                .padding(.top, 40)
                .background(alignment: .topLeading) {
                    RadialGradient(colors: [Theme.tint(for: name).opacity(0.8), .clear], center: .topLeading, startRadius: 0, endRadius: 900)
                        .frame(width: 1920, height: 900)
                        .offset(y: -300)
                        .allowsHitTesting(false)
                }

                CardGrid(list: list, shape: .square, emptyIcon: "square.stack", emptyTitle: "No albums yet")
            }
            .padding(.bottom, 100)
        }
        .scrollClipDisabled()
        .ignoresSafeArea(edges: .horizontal)
        .background(Theme.Colors.background.ignoresSafeArea())
        .task(id: name) {
            let genre = name
            await list.reload(using: appState) { client, offset, limit in
                try await client.albums(sort: .title, genre: genre, limit: limit, offset: offset)
            }
        }
    }

    private func shuffle() async {
        guard let client = appState.client else { return }
        actionError = nil
        do {
            let tracks = try await client.shuffle(.genre(name))
            if tracks.isEmpty {
                actionError = String(localized: "There are no songs to play.")
            } else {
                audio.play(tracks: tracks)
            }
        } catch {
            actionError = appState.message(for: error)
        }
    }
}
