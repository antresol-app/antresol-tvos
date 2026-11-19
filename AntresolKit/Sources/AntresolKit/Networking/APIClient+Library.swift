import Foundation

// Movies and series, search, progress, watched state and watchlist (§4, §6).
extension APIClient {
    /// `GET /api/home`: only the cards the app can open, each once (`HomeResponse.openable`);
    /// every screen built on Home, and the Top Shelf, relies on it.
    public func home() async throws -> HomeResponse {
        let home: HomeResponse = try await send(.get, "/api/home")
        return home.openable
    }

    /// `GET /api/items`. `kind` is `.movie`, `.series`, or nil for both.
    public func items(kind: ItemKind?, sort: ItemSort = .recent, limit: Int? = APIClient.defaultPageSize, offset: Int = 0) async throws -> Page<Card> {
        var query: [URLQueryItem] = []
        if let kind { query.append(URLQueryItem(name: "kind", value: kind.rawValue)) }
        query.append(URLQueryItem(name: "sort", value: sort.rawValue))
        return try await send(.get, "/api/items", query: query + APIClient.paging(limit: limit, offset: offset))
    }

    /// `GET /api/items/{id}` for a movie, series, season or episode.
    public func item(id: Int) async throws -> ItemDetail {
        try await send(.get, "/api/items/\(id)")
    }

    /// `GET /api/tracking/{series|movie}/{tmdbId}/episodes` (server 0.5.0+): every episode
    /// of the title, downloaded or not. Older servers answer 404 or 405, as does a title the
    /// profile's age filter hides; callers then keep the library's list.
    public func trackingEpisodes(kind: ItemKind, tmdbId: Int) async throws -> TrackingEpisodes {
        try await send(.get, "/api/tracking/\(kind == .movie ? "movie" : "series")/\(tmdbId)/episodes")
    }

    /// `GET /api/items/{id}/trailers`: a movie's or series' trailers (a season or episode
    /// answers with its series'). The server answers an empty list, not an error, when it
    /// has none; older servers answer 404, which callers treat as none.
    public func trailers(itemId: Int) async throws -> [Trailer] {
        let list: TrailerList = try await send(.get, "/api/items/\(itemId)/trailers")
        return list.trailers
    }

    /// `GET /api/search?q=`.
    public func search(_ text: String) async throws -> SearchResults {
        try await send(.get, "/api/search", query: [URLQueryItem(name: "q", value: text)])
    }

    /// `GET /api/progress/{itemId}`.
    public func progress(itemId: Int) async throws -> PlaybackProgress {
        try await send(.get, "/api/progress/\(itemId)")
    }

    /// `PUT /api/progress/{itemId}` for a movie, episode, audiobook, book or comic volume.
    public func updateProgress(itemId: Int, _ update: ProgressUpdate) async throws {
        try await sendWithoutResponse(.put, "/api/progress/\(itemId)", json: update)
    }

    /// `POST /api/items/{id}/watched`. `false` deletes the stored progress.
    public func setWatched(itemId: Int, _ watched: Bool) async throws {
        try await sendWithoutResponse(.post, "/api/items/\(itemId)/watched", json: ["watched": watched])
    }

    /// `POST` / `DELETE /api/watchlist/{itemId}`.
    public func setInWatchlist(itemId: Int, _ inWatchlist: Bool) async throws {
        try await sendWithoutResponse(inWatchlist ? .post : .delete, "/api/watchlist/\(itemId)")
    }
}
