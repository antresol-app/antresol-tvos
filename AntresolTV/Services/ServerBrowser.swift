import AntresolKit
import Foundation
import Network
import Observation

/// Finds Antresol servers on the home network with Bonjour (`_antresol._tcp`, the
/// contract's DNS-SD advertisement). Each sighting is resolved to an IPv4 address and
/// confirmed with `/api/health` (same `serverId` as the TXT `id`) before it is listed.
///
/// Apple platforms use Bonjour only: a UDP broadcast probe would need Apple's multicast
/// entitlement. The address field stays for everything Bonjour cannot see (Docker's
/// bridge network, another subnet, an address outside the home).
@MainActor
@Observable
final class ServerBrowser {
    /// Confirmed servers, one per server id, by name.
    private(set) var servers: [DiscoveredServer] = []
    /// The system refused local network access (Settings > Privacy > Local Network).
    private(set) var isDenied = false
    /// Browsing runs and has not been refused.
    private(set) var isBrowsing = false

    @ObservationIgnored private var browser: NWBrowser?
    @ObservationIgnored private var found: [NWEndpoint: DiscoveredServer] = [:]
    @ObservationIgnored private var resolving: [NWEndpoint: Task<Void, Never>] = [:]

    func start() {
        guard browser == nil else { return }
        let parameters = NWParameters()
        parameters.includePeerToPeer = false
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: ServerDiscovery.serviceType, domain: nil), using: parameters)
        browser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in self?.handle(state) }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor in self?.update(results) }
        }
        self.browser = browser
        isBrowsing = true
        browser.start(queue: .main)
    }

    func stop() {
        browser?.cancel()
        browser = nil
        resolving.values.forEach { $0.cancel() }
        resolving = [:]
        isBrowsing = false
    }

    private func handle(_ state: NWBrowser.State) {
        switch state {
        case .ready:
            isDenied = false
            isBrowsing = true
        case .waiting(let error), .failed(let error):
            if Self.isPolicyDenied(error) {
                isDenied = true
                isBrowsing = false
            }
            if case .failed = state {
                // restart once the network comes back; the next `start` makes a new browser
                browser?.cancel()
                browser = nil
                isBrowsing = false
            }
        case .cancelled:
            isBrowsing = false
        default:
            break
        }
    }

    private func update(_ results: Set<NWBrowser.Result>) {
        let current = Set(results.map(\.endpoint))
        for endpoint in found.keys where !current.contains(endpoint) {
            found[endpoint] = nil
        }
        for endpoint in resolving.keys where !current.contains(endpoint) {
            resolving[endpoint]?.cancel()
            resolving[endpoint] = nil
        }
        for result in results where found[result.endpoint] == nil && resolving[result.endpoint] == nil {
            guard case .bonjour(let txt) = result.metadata,
                  let ad = ServerDiscovery.advertisement(fromTXT: txt.dictionary)
            else { continue }
            let endpoint = result.endpoint
            resolving[endpoint] = Task { [weak self] in
                let server = await Self.confirm(endpoint, advertisement: ad)
                guard let self, !Task.isCancelled else { return }
                self.resolving[endpoint] = nil
                if let server { self.found[endpoint] = server }
                self.publish()
            }
        }
        publish()
    }

    private func publish() {
        let list = DiscoveredServer.merged(Array(found.values))
        if list != servers { servers = list }
    }

    /// Resolves the service to an IPv4 address and port, then checks `/api/health` there.
    nonisolated private static func confirm(_ endpoint: NWEndpoint, advertisement: ServerDiscovery.Advertisement) async -> DiscoveredServer? {
        guard let (host, port) = await resolve(endpoint),
              let url = ServerDiscovery.baseURL(host: host, port: port, advertisement: advertisement)
        else { return nil }
        let client = APIClient(baseURL: url, transport: URLSessionTransport(session: probeSession))
        guard let health = try? await client.health(), health.serverId == advertisement.id else { return nil }
        return DiscoveredServer(id: health.serverId, name: advertisement.name,
                                version: health.version.isEmpty ? advertisement.version : health.version, baseURL: url)
    }

    /// The service's IPv4 address and port: a TCP connection over IPv4 reports the
    /// endpoint it reached (the server advertises IPv4 only).
    nonisolated private static func resolve(_ endpoint: NWEndpoint) async -> (String, Int)? {
        let parameters = NWParameters.tcp
        if let ip = parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            ip.version = .v4
        }
        let connection = NWConnection(to: endpoint, using: parameters)
        let waiting = Locked<CheckedContinuation<(String, Int)?, Never>?>(nil)
        // Resumes the continuation at most once (connection callbacks can arrive more than once).
        let finish: @Sendable ((String, Int)?) -> Void = { answer in
            waiting.withLock { pending -> CheckedContinuation<(String, Int)?, Never>? in
                defer { pending = nil }
                return pending
            }?.resume(returning: answer)
        }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<(String, Int)?, Never>) in
                waiting.withLock { $0 = continuation }
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        var answer: (String, Int)?
                        if case .hostPort(let host, let port)? = connection.currentPath?.remoteEndpoint {
                            answer = (host.text, Int(port.rawValue))
                        }
                        connection.cancel()
                        finish(answer)
                    case .failed, .waiting:
                        connection.cancel()
                        finish(nil)
                    case .cancelled:
                        finish(nil)
                    default:
                        break
                    }
                }
                connection.start(queue: .global(qos: .utility))
                DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
                    connection.cancel()
                    finish(nil)
                }
            }
        } onCancel: {
            connection.cancel()
        }
    }

    /// `kDNSServiceErr_PolicyDenied`: the user turned local network access off.
    nonisolated private static func isPolicyDenied(_ error: NWError) -> Bool {
        if case .dns(let code) = error { return code == -65570 }
        return false
    }

    /// Short timeouts: a sighting that does not answer quickly is not listed.
    nonisolated private static let probeSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 4
        config.timeoutIntervalForResource = 6
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()
}
