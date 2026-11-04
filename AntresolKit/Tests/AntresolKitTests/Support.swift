import Foundation
import XCTest
@testable import AntresolKit
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

enum Samples {
    static func data(_ name: String) throws -> Data {
        guard let url = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Samples") else {
            throw XCTSkip("Missing sample \(name)")
        }
        return try Data(contentsOf: url)
    }

    static func decode<T: Decodable>(_ type: T.Type, _ name: String) throws -> T {
        try JSONDecoder().decode(T.self, from: data(name))
    }

    static var allJSONNames: [String] {
        guard let dir = Bundle.module.url(forResource: "Samples", withExtension: nil),
              let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path)
        else { return [] }
        return names.filter { $0.hasSuffix(".json") }.sorted()
    }
}

/// A scripted transport that records requests.
final class MockTransport: HTTPTransport, @unchecked Sendable {
    struct Reply {
        var status: Int
        var body: Data
        var headers: [String: String]

        static func json(_ text: String, status: Int = 200, headers: [String: String] = [:]) -> Reply {
            Reply(status: status, body: Data(text.utf8), headers: headers)
        }

        static let noContent = Reply(status: 204, body: Data(), headers: [:])
    }

    private let handler: (URLRequest) -> Reply
    private let recorded = Locked<[URLRequest]>([])

    init(_ handler: @escaping (URLRequest) -> Reply) {
        self.handler = handler
    }

    var requests: [URLRequest] {
        recorded.current
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        recorded.withLock { $0.append(request) }
        let reply = handler(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers)!
        return (reply.body, response)
    }
}

extension URLRequest {
    var bodyJSON: [String: Any]? {
        guard let body = httpBody else { return nil }
        return (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
    }

    var pathAndQuery: String {
        guard let url else { return "" }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        return (components?.percentEncodedPath ?? "") + (components?.percentEncodedQuery.map { "?" + $0 } ?? "")
    }
}
