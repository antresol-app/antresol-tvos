import Foundation

// The kid profile's «Попросить»: the server's `/api/requests…`, the same calls the web makes.
// Only a kid's profile gets answers, and only while requests are open on the server (`canRequest`
// of `GET /api/me`).
extension APIClient {
    /// `GET /api/requests/search?q=&kind=`: what a kid may see and ask for, each with where its
    /// request stands. A result in a format this app does not know is left out.
    public func requestSearch(_ text: String, kind: RequestSearchKind) async throws -> [KidCandidate] {
        let list: [Lenient<KidCandidate>] = try await send(
            .get, "/api/requests/search",
            query: [URLQueryItem(name: "q", value: text), URLQueryItem(name: "kind", value: kind.rawValue)]
        )
        return list.compactMap(\.value)
    }

    /// `POST /api/requests`: the kid's request of the title, made once (asking again returns
    /// it). A 403 whose `code` is `rating` carries the server's words: the title is above the
    /// profile's age limit.
    public func askRequest(_ ask: KidRequestAsk) async throws -> KidRequest {
        try await send(.post, "/api/requests", json: ask)
    }

    /// `GET /api/requests/mine`: the profile's requests, newest first.
    public func myRequests() async throws -> [KidRequest] {
        let list: [Lenient<KidRequest>] = try await send(.get, "/api/requests/mine")
        return list.compactMap(\.value)
    }
}
