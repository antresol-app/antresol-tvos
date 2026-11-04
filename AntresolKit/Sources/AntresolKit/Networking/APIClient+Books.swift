import Foundation

// Books, audiobooks and comics (§8).
extension APIClient {
    /// `GET /api/books/home`.
    public func booksHome() async throws -> ShelvesResponse {
        try await send(.get, "/api/books/home")
    }

    /// `GET /api/books?kind=`.
    public func books(kind: BookListKind, sort: BookSort = .added, limit: Int? = APIClient.defaultPageSize, offset: Int = 0) async throws -> Page<Card> {
        let query = [URLQueryItem(name: "kind", value: kind.rawValue), URLQueryItem(name: "sort", value: sort.rawValue)]
        return try await send(.get, "/api/books", query: query + APIClient.paging(limit: limit, offset: offset))
    }

    /// `GET /api/books/{id}` for a book, audiobook, comic series or comic volume.
    public func book(id: Int) async throws -> BookDetail {
        try await send(.get, "/api/books/\(id)")
    }

    /// `GET /api/comics/{fileId}/pages`.
    public func comicPages(fileId: Int) async throws -> ComicPages {
        try await send(.get, "/api/comics/\(fileId)/pages")
    }

    /// Downloads one comic page image; `index` is 0-based.
    public func comicPage(fileId: Int, index: Int) async throws -> Data {
        try await data(path: "/api/comics/\(fileId)/page/\(index)")
    }
}
