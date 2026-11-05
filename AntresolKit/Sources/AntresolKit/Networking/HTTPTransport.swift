import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Sends a request and returns the raw response. Abstracted so tests can stub the network.
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// `URLSession`-backed transport.
public struct URLSessionTransport: HTTPTransport, @unchecked Sendable {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let box = Locked<URLSessionDataTask?>(nil)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let task = session.dataTask(with: request) { data, response, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else if let http = response as? HTTPURLResponse {
                        continuation.resume(returning: (data ?? Data(), http))
                    } else {
                        continuation.resume(throwing: URLError(.badServerResponse))
                    }
                }
                box.withLock { $0 = task }
                // A cancellation that came before the task was stored found nothing to cancel.
                if Task.isCancelled { task.cancel() }
                task.resume()
            }
        } onCancel: {
            box.current?.cancel()
        }
    }
}
