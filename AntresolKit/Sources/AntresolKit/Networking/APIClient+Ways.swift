import Foundation

// The addons' `x/app` protocol, through the core's `/api/addons/{id}/x/…` proxy, and the core's
// own routes it leans on: the open addons (`/api/addons/web`), a title off the library
// (`/api/title`) and the input player (`/api/play/input`, see `APIClient+InputPlay`).
extension APIClient {
    /// How long a step (looking for sources can take most of half a minute) or a run (an addon
    /// getting a stream ready) is waited for.
    static let wayStepTimeout: TimeInterval = 60
    static let wayRunTimeout: TimeInterval = 100

    /// `GET /api/addons/web`: the ids of the addons open to the profile (a kid gets none: `403`).
    /// Nothing else of the list is used.
    public func openAddonIds() async throws -> [String] {
        struct Entry: Decodable {
            var id: String?
            enum CodingKeys: String, CodingKey { case id }
            init(from decoder: Decoder) throws {
                id = try? decoder.container(keyedBy: CodingKeys.self).decodeIfPresent(String.self, forKey: .id)
            }
        }
        let entries: [Lenient<Entry>] = try await send(.get, "/api/addons/web")
        return entries.compactMap { $0.value?.id }.filter(AddonID.isValid)
    }

    /// `GET /api/addons/{id}/x/app`.
    public func appInfo(addon: String) async throws -> AppInfo {
        try await send(.get, try wayPath(addon, "app"))
    }

    /// `GET x/app/search?q=`.
    public func addonTitles(addon: String, query: String) async throws -> [AddonTitle] {
        let list: AddonTitleList = try await send(.get, try wayPath(addon, "app/search"), query: [URLQueryItem(name: "q", value: query)])
        return list.titles
    }

    /// `POST x/app/step`.
    public func wayStep(addon: String, _ body: WayStepRequest) async throws -> WayStep {
        try await sendLong(.post, try wayPath(addon, "app/step"), json: body, timeout: Self.wayStepTimeout)
    }

    /// `POST x/app/run`.
    public func wayRun(addon: String, _ body: WayRunRequest) async throws -> WayRunResult {
        try await sendLong(.post, try wayPath(addon, "app/run"), json: body, timeout: Self.wayRunTimeout)
    }

    /// `GET x/app/state?kind=&tmdbId=[&season=]`: the state of each way of the addon for a title.
    public func wayStates(addon: String, target: WayTarget) async throws -> [String: WayState] {
        var query = [URLQueryItem(name: "kind", value: target.kind), URLQueryItem(name: "tmdbId", value: String(target.tmdbId))]
        if let season = target.season { query.append(URLQueryItem(name: "season", value: String(season))) }
        let states: WayStates = try await send(.get, try wayPath(addon, "app/state"), query: query)
        return states.ways
    }

    /// `POST x/app/cancel`: the notice to show, if the addon sent one.
    @discardableResult
    public func wayCancel(addon: String, _ body: WayCancelRequest) async throws -> String? {
        let answer: WayDone = try await send(.post, try wayPath(addon, "app/cancel"), json: body)
        return answer.done
    }

    /// `PUT x/app/progress` of a directly played way (`WayPlay.progress.path`) → 204.
    public func wayProgress(addon: String, path: String = WayProgressSpec.defaultPath, _ body: WayProgressUpdate) async throws {
        try await sendWithoutResponse(.put, try wayPath(addon, String(path.dropFirst("x/".count))), json: body)
    }

    /// `DELETE x/app/play/{session}` → 204, when the player of a directly played way closes.
    public func wayStopPlay(addon: String, session: String) async throws {
        try await sendWithoutResponse(.delete, try wayPath(addon, "app/play/" + ServerURLs.encode(session)))
    }

    /// `GET /api/title/{kind}/{tmdbId}`: a TMDB movie or series, in the library or not.
    public func titleInfo(kind: String, tmdbId: Int) async throws -> TitleInfo {
        guard WayTarget(kind: kind, tmdbId: tmdbId, inLibrary: false).isTitle else { throw APIError.invalidURL("title \(kind)") }
        return try await send(.get, "/api/title/\(kind)/\(tmdbId)")
    }

    /// `/api/addons/{id}/x/{rest}`: the addon's own path under the core's proxy. An id that is
    /// not a plain word is refused, so a path never leaves the addon's.
    func wayPath(_ addon: String, _ rest: String) throws -> String {
        guard AddonID.isValid(addon) else { throw APIError.invalidURL("addon \(addon)") }
        return "/api/addons/\(addon)/x/\(rest)"
    }

    /// A JSON request that may take a while.
    func sendLong<Response: Decodable, Body: Encodable>(
        _ method: Method, _ path: String, json body: Body, timeout: TimeInterval
    ) async throws -> Response {
        var request = try makeRequest(method, path, body: try APIClient.encoder.encode(body))
        request.timeoutInterval = timeout
        let (data, _) = try await perform(request)
        do {
            return try APIClient.decoder.decode(Response.self, from: data)
        } catch {
            throw APIError.decoding("\(method.rawValue) \(path): \(error)")
        }
    }
}

extension WayTarget {
    /// `movie` or `series` with a TMDB id: what the core's title page takes.
    var isTitle: Bool {
        (kind == "movie" || kind == "series") && tmdbId > 0
    }
}
