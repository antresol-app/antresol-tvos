import Foundation

/// A request read by the TV setup listener: just what `/setup` needs (HTTP/1.x, one
/// request per connection, `Content-Length` bodies only).
public struct HTTPRequest: Equatable, Sendable {
    public var method: String
    /// The path without the query, e.g. `/setup`.
    public var path: String
    public var query: [String: String]
    /// Header names in lower case.
    public var headers: [String: String]
    public var body: Data

    public init(method: String, path: String, query: [String: String] = [:], headers: [String: String] = [:], body: Data = Data()) {
        self.method = method
        self.path = path
        self.query = query
        self.headers = headers
        self.body = body
    }

    public func header(_ name: String) -> String? { headers[name.lowercased()] }

    /// Where a request stands after the bytes received so far.
    public enum Parse: Equatable, Sendable {
        /// Keep reading.
        case incomplete
        case complete(HTTPRequest)
        /// Malformed or over the limits: answer `status` and close.
        case invalid(status: Int)
    }

    /// Limits: the head (request line + headers) and the body.
    public static let maxHeadBytes = 8 * 1024
    public static let maxBodyBytes = 4 * 1024

    private static let headEnd = Data("\r\n\r\n".utf8)

    /// Parses the bytes of one request received so far.
    public static func parse(_ data: Data) -> Parse {
        guard let end = data.range(of: headEnd) else {
            return data.count > maxHeadBytes ? .invalid(status: 431) : .incomplete
        }
        guard end.lowerBound - data.startIndex <= maxHeadBytes else { return .invalid(status: 431) }
        guard let head = String(data: data[data.startIndex..<end.lowerBound], encoding: .utf8) else {
            return .invalid(status: 400)
        }
        let lines = head.components(separatedBy: "\r\n")
        let requestLine = lines[0].split(separator: " ", omittingEmptySubsequences: true)
        guard requestLine.count == 3, requestLine[2].hasPrefix("HTTP/1.") else { return .invalid(status: 400) }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { return .invalid(status: 400) }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return .invalid(status: 400) }
            headers[name] = headers[name].map { "\($0), \(value)" } ?? value
        }
        if headers["transfer-encoding"] != nil { return .invalid(status: 411) }
        var length = 0
        if let text = headers["content-length"] {
            guard let value = Int(text), value >= 0 else { return .invalid(status: 400) }
            length = value
        }
        guard length <= maxBodyBytes else { return .invalid(status: 413) }
        let bodyStart = end.upperBound
        let received = data.endIndex - bodyStart
        guard received >= length else { return .incomplete }
        let body = Data(data[bodyStart..<(bodyStart + length)])

        let target = String(requestLine[1])
        var path = target
        var query: [String: String] = [:]
        if let mark = target.firstIndex(of: "?") {
            path = String(target[..<mark])
            query = TVSetupSubmission.formFields(String(target[target.index(after: mark)...]))
        }
        return .complete(HTTPRequest(method: String(requestLine[0]).uppercased(), path: path, query: query, headers: headers, body: body))
    }

    /// Whether the client prefers Russian (`Accept-Language` starting with `ru`, before
    /// any English).
    public var prefersRussian: Bool {
        guard let header = header("accept-language")?.lowercased() else { return false }
        for tag in header.split(separator: ",") {
            let lang = tag.split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
            if lang.hasPrefix("ru") { return true }
            if lang.hasPrefix("en") { return false }
        }
        return false
    }
}

/// A response of the TV setup listener; always `Connection: close`.
public struct HTTPResponse: Equatable, Sendable {
    public var status: Int
    public var headers: [(String, String)]
    public var body: Data

    public init(status: Int, headers: [(String, String)] = [], body: Data = Data()) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    public static func == (a: HTTPResponse, b: HTTPResponse) -> Bool {
        a.status == b.status && a.body == b.body && a.headers.map { "\($0.0): \($0.1)" } == b.headers.map { "\($0.0): \($0.1)" }
    }

    public func header(_ name: String) -> String? {
        headers.first { $0.0.lowercased() == name.lowercased() }?.1
    }

    public static func json<T: Encodable>(_ status: Int, _ value: T, headers: [(String, String)] = []) -> HTTPResponse {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let body = (try? encoder.encode(value)) ?? Data("{}".utf8)
        return HTTPResponse(status: status, headers: [("Content-Type", "application/json; charset=utf-8")] + headers, body: body)
    }

    public static func html(_ status: Int, _ page: String, headers: [(String, String)] = []) -> HTTPResponse {
        HTTPResponse(status: status, headers: [("Content-Type", "text/html; charset=utf-8")] + headers, body: Data(page.utf8))
    }

    public static func plain(_ status: Int) -> HTTPResponse {
        HTTPResponse(status: status, headers: [("Content-Type", "text/plain; charset=utf-8")], body: Data(reason(status).utf8))
    }

    /// The bytes on the wire.
    public func serialized() -> Data {
        var head = "HTTP/1.1 \(status) \(Self.reason(status))\r\n"
        for (name, value) in headers {
            head += "\(name): \(value)\r\n"
        }
        head += "Content-Length: \(body.count)\r\n"
        head += "Cache-Control: no-store\r\n"
        head += "Connection: close\r\n\r\n"
        return Data(head.utf8) + body
    }

    static func reason(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 303: return "See Other"
        case 400: return "Bad Request"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 409: return "Conflict"
        case 411: return "Length Required"
        case 413: return "Payload Too Large"
        case 422: return "Unprocessable Content"
        case 429: return "Too Many Requests"
        case 431: return "Request Header Fields Too Large"
        case 502: return "Bad Gateway"
        default: return "Error"
        }
    }
}
