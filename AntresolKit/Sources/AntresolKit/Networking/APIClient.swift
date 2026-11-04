import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// HTTP client for the native `/api` interface of an Antresol server.
///
/// Every request carries `Authorization: Bearer <token>` (once signed in) and
/// `Accept-Language`; JSON bodies carry `Content-Type: application/json`. No
/// `Origin` header is ever sent, so the server's CSRF guard accepts mutations.
public final class APIClient: Sendable {
    public enum Method: String, Sendable {
        case get = "GET", post = "POST", put = "PUT", patch = "PATCH", delete = "DELETE"
    }

    /// Server base URL, e.g. `http://192.168.1.10:8420`.
    public let baseURL: URL
    private let transport: HTTPTransport
    private let state: Locked<State>

    private struct State {
        var token: String?
        var language: String
    }

    public init(baseURL: URL, token: String? = nil, language: String = "en", transport: HTTPTransport = URLSessionTransport()) {
        self.baseURL = baseURL
        self.transport = transport
        self.state = Locked(State(token: token, language: APIClient.normalizeLanguage(language)))
    }

    /// The device token used for `Authorization`.
    public var token: String? {
        get { state.withLock { $0.token } }
        set { state.withLock { $0.token = newValue } }
    }

    /// `en` or `ru`. The server defaults to Russian, so this is always sent.
    public var language: String {
        get { state.withLock { $0.language } }
        set { state.withLock { $0.language = APIClient.normalizeLanguage(newValue) } }
    }

    /// Builders for image, stream and other media URLs on this server.
    public var urls: ServerURLs {
        ServerURLs(baseURL: baseURL)
    }

    /// Headers to attach when another component loads server URLs (images, subtitles,
    /// comic pages): Bearer auth plus language.
    public var authorizationHeaders: [String: String] {
        var headers = ["Accept-Language": language]
        if let token { headers["Authorization"] = "Bearer \(token)" }
        return headers
    }

    /// Maps a preferred language (e.g. `ru-RU`) to one the server supports.
    public static func normalizeLanguage(_ language: String) -> String {
        language.lowercased().hasPrefix("ru") ? "ru" : "en"
    }

    // MARK: - Request plumbing

    static let encoder = JSONEncoder()
    static let decoder = JSONDecoder()

    func makeRequest(_ method: Method, _ path: String, query: [URLQueryItem] = [], body: Data? = nil) throws -> URLRequest {
        guard let url = urls.url(path: path, query: query) else {
            throw APIError.invalidURL(path)
        }
        var request = URLRequest(url: url)
        request.httpMethod = method.rawValue
        request.timeoutInterval = 30
        for (name, value) in authorizationHeaders {
            request.setValue(value, forHTTPHeaderField: name)
        }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    /// Performs a request and returns the body of a 2xx response.
    func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport.send(request)
        } catch let error as APIError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if let urlError = error as? URLError, urlError.code == .cancelled {
                throw CancellationError()
            }
            throw APIError.transport(error.localizedDescription)
        }
        guard (200..<300).contains(response.statusCode) else {
            throw APIClient.error(status: response.statusCode, data: data, response: response)
        }
        return (data, response)
    }

    static func error(status: Int, data: Data, response: HTTPURLResponse) -> APIError {
        let body = try? decoder.decode(ErrorBody.self, from: data)
        let message = body?.error ?? String(data: data, encoding: .utf8).flatMap { text in
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if status == 401 {
            return .unauthorized(message: message)
        }
        let retryAfter = response.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init)
        return .server(status: status, message: message, code: body?.code, retryAfter: retryAfter)
    }

    func send<Response: Decodable>(
        _ method: Method, _ path: String, query: [URLQueryItem] = [], body: Data? = nil,
        as type: Response.Type = Response.self
    ) async throws -> Response {
        let request = try makeRequest(method, path, query: query, body: body)
        let (data, _) = try await perform(request)
        do {
            return try APIClient.decoder.decode(Response.self, from: data)
        } catch {
            throw APIError.decoding("\(method.rawValue) \(path): \(error)")
        }
    }

    func send<Response: Decodable, Body: Encodable>(
        _ method: Method, _ path: String, query: [URLQueryItem] = [], json body: Body,
        as type: Response.Type = Response.self
    ) async throws -> Response {
        try await send(method, path, query: query, body: try APIClient.encoder.encode(body), as: type)
    }

    func sendWithoutResponse(_ method: Method, _ path: String, query: [URLQueryItem] = [], body: Data? = nil) async throws {
        let request = try makeRequest(method, path, query: query, body: body)
        _ = try await perform(request)
    }

    func sendWithoutResponse<Body: Encodable>(_ method: Method, _ path: String, json body: Body) async throws {
        try await sendWithoutResponse(method, path, body: try APIClient.encoder.encode(body))
    }

    /// Fetches raw bytes of an authenticated server resource (images, subtitles, comic pages).
    public func data(path: String) async throws -> Data {
        let request = try makeRequest(.get, path)
        return try await perform(request).0
    }

    static func paging(limit: Int?, offset: Int?) -> [URLQueryItem] {
        var items: [URLQueryItem] = []
        if let limit { items.append(URLQueryItem(name: "limit", value: String(limit))) }
        if let offset, offset > 0 { items.append(URLQueryItem(name: "offset", value: String(offset))) }
        return items
    }

    /// The page size the web app uses everywhere.
    public static let defaultPageSize = 120
}
