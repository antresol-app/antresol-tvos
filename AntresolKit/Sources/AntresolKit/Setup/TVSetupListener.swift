#if canImport(Network)
import Foundation
import Network

/// The TV setup endpoint's socket: a TCP listener on a random free port that reads one
/// HTTP request per connection, hands it to `TVSetupHandler` with the client's address
/// and writes the answer. Apple platforms only (Network framework); the logic it serves
/// is plain Foundation.
public final class TVSetupListener: @unchecked Sendable {
    /// A connection that has not sent a whole request by then is closed.
    public static let connectionTimeout: TimeInterval = 15

    private let handler: TVSetupHandler
    private let host: String?
    private let queue = DispatchQueue(label: "antresol.tv-setup")
    private var listener: NWListener?

    /// `host`: the local IPv4 to listen on (the TV's LAN address, or `127.0.0.1` in
    /// tests); nil listens on every interface.
    public init(handler: TVSetupHandler, host: String?) {
        self.handler = handler
        self.host = host
    }

    /// Starts listening; returns the port once the listener is ready.
    public func start() async throws -> UInt16 {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        if let host {
            parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(host), port: .any)
        }
        let listener = try NWListener(using: parameters)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            self?.serve(connection)
        }
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UInt16, Error>) in
            let resumed = Locked(false)
            listener.stateUpdateHandler = { state in
                func resume(_ result: Result<UInt16, Error>) {
                    let first = resumed.withLock { done -> Bool in
                        defer { done = true }
                        return !done
                    }
                    if first { continuation.resume(with: result) }
                }
                switch state {
                case .ready:
                    if let port = listener.port?.rawValue {
                        resume(.success(port))
                    } else {
                        resume(.failure(NWError.posix(.EADDRNOTAVAIL)))
                    }
                case .failed(let error), .waiting(let error):
                    listener.cancel()
                    resume(.failure(error))
                case .cancelled:
                    resume(.failure(CancellationError()))
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    /// Stops accepting connections. Requests already being answered finish.
    public func stop() {
        listener?.cancel()
        listener = nil
    }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + Self.connectionTimeout) { [weak connection] in
            connection?.cancel()
        }
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { connection.cancel(); return }
            var buffer = buffer
            if let data { buffer.append(data) }
            switch HTTPRequest.parse(buffer) {
            case .incomplete:
                if isComplete || error != nil {
                    connection.cancel()
                } else {
                    self.receive(on: connection, buffer: buffer)
                }
            case .invalid(let status):
                self.send(HTTPResponse.plain(status), on: connection)
            case .complete(let request):
                let address = Self.address(of: connection.endpoint)
                let handler = self.handler
                Task {
                    let response = await handler.respond(to: request, from: address)
                    self.send(response, on: connection)
                }
            }
        }
    }

    private func send(_ response: HTTPResponse, on connection: NWConnection) {
        connection.send(content: response.serialized(), contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    /// The client's IP as text ("" when it is not an IP endpoint).
    static func address(of endpoint: NWEndpoint) -> String {
        guard case .hostPort(let host, _) = endpoint else { return "" }
        return host.text
    }
}
#endif
