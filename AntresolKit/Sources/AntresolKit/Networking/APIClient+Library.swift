import Foundation

// Movies and series, search, progress, watched state and watchlist (§4, §6).
extension APIClient {
    /// `GET /api/home`.
    public func home() async throws -> HomeResponse {
        try await send(.get, "/api/home")
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
