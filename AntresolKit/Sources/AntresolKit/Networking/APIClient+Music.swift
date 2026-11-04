import Foundation

// Music (§7).
extension APIClient {
    /// `GET /api/music/home`.
    public func musicHome() async throws -> ShelvesResponse {
        try await send(.get, "/api/music/home")
    }

    /// `GET /api/music/albums`.
    public func albums(
        sort: AlbumSort = .added, genre: String? = nil, artistId: Int? = nil, starred: Bool = false,
        limit: Int? = APIClient.defaultPageSize, offset: Int = 0
    ) async throws -> Page<Card> {
        var query = [URLQueryItem(name: "sort", value: sort.rawValue)]
        if let genre { query.append(URLQueryItem(name: "genre", value: genre)) }
        if let artistId { query.append(URLQueryItem(name: "artist", value: String(artistId))) }
        if starred { query.append(URLQueryItem(name: "starred", value: "1")) }
        return try await send(.get, "/api/music/albums", query: query + APIClient.paging(limit: limit, offset: offset))
    }

    /// `GET /api/music/albums/{id}`.
    public func album(id: Int) async throws -> AlbumDetail {
        try await send(.get, "/api/music/albums/\(id)")
    }

    /// `GET /api/music/artists`.
    public func artists(starred: Bool = false, limit: Int? = APIClient.defaultPageSize, offset: Int = 0) async throws -> Page<Card> {
        let query = starred ? [URLQueryItem(name: "starred", value: "1")] : []
        return try await send(.get, "/api/music/artists", query: query + APIClient.paging(limit: limit, offset: offset))
    }

    /// `GET /api/music/artists/{id}`.
    public func artist(id: Int) async throws -> ArtistDetail {
        try await send(.get, "/api/music/artists/\(id)")
    }

    /// `GET /api/music/songs`.
    public func songs(starred: Bool = false, limit: Int? = APIClient.defaultPageSize, offset: Int = 0) async throws -> Page<Track> {
        let query = starred ? [URLQueryItem(name: "starred", value: "1")] : []
        return try await send(.get, "/api/music/songs", query: query + APIClient.paging(limit: limit, offset: offset))
    }

    /// `GET /api/music/tracks/{id}`.
    public func track(id: Int) async throws -> Track {
        try await send(.get, "/api/music/tracks/\(id)")
    }

    /// `GET /api/music/genres`.
    public func genres() async throws -> [Genre] {
        try await send(.get, "/api/music/genres", as: GenresResponse.self).genres
    }

    /// `GET /api/music/shuffle`: a random queue.
    public func shuffle(_ source: ShuffleSource = .all) async throws -> [Track] {
        try await send(.get, "/api/music/shuffle", query: source.queryItems, as: ShuffleResponse.self).tracks
    }

    /// `GET /api/music/tracks/{id}/lyrics`; nil when the track has no lyrics.
    public func lyrics(trackId: Int) async throws -> Lyrics? {
        do {
            return try await send(.get, "/api/music/tracks/\(trackId)/lyrics")
        } catch let error as APIError where error.isNotFound {
            return nil
        }
    }

    /// `POST /api/music/plays`: scrobbles one play of a track.
    public func recordPlay(trackId: Int, at date: Date? = nil) async throws {
        try await sendWithoutResponse(.post, "/api/music/plays", json: PlayRecord(trackId: trackId, at: date.map(Timestamp.format)))
    }

    /// `POST` / `DELETE /api/music/star/{itemId}` for a track, album or artist.
    public func setStarred(itemId: Int, _ starred: Bool) async throws {
        try await sendWithoutResponse(starred ? .post : .delete, "/api/music/star/\(itemId)")
    }

    /// `GET /api/music/playlists`.
    public func playlists() async throws -> [Playlist] {
        try await send(.get, "/api/music/playlists", as: ItemsEnvelope<Playlist>.self).items
    }

    /// `GET /api/music/playlists/{id}`.
    public func playlist(id: Int) async throws -> PlaylistDetail {
        try await send(.get, "/api/music/playlists/\(id)")
    }

    /// `POST /api/music/playlists`.
    public func createPlaylist(name: String, trackIds: [Int] = []) async throws -> Playlist {
        try await send(.post, "/api/music/playlists", json: PlaylistCreate(name: name, trackIds: trackIds.isEmpty ? nil : trackIds))
    }

    /// `PATCH /api/music/playlists/{id}`.
    public func updatePlaylist(id: Int, _ update: PlaylistUpdate) async throws -> Playlist {
        try await send(.patch, "/api/music/playlists/\(id)", json: update)
    }

    /// `DELETE /api/music/playlists/{id}`.
    public func deletePlaylist(id: Int) async throws {
        try await sendWithoutResponse(.delete, "/api/music/playlists/\(id)")
    }
}
