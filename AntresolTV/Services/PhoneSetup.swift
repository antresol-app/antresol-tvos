import AntresolKit
import Darwin
import Foundation
import Observation

/// The TV setup endpoint while "Set up with your phone" is on screen: a listener on the
/// Apple TV's LAN address and a random port, the QR code's URL, and a new nonce every
/// time it starts (and when one runs out). Stop it when the screen goes away.
@MainActor
@Observable
final class PhoneSetup {
    enum Status: Equatable {
        case starting
        /// The QR code's text.
        case ready(url: String)
        /// No LAN IPv4, or the listener could not open: only the remote fallbacks work.
        case unavailable
    }

    private(set) var status: Status = .starting
    @ObservationIgnored private var listener: TVSetupListener?
    @ObservationIgnored private var handler: TVSetupHandler?
    @ObservationIgnored private var task: Task<Void, Never>?

    /// Opens the endpoint; `perform` does the setup (`AppState.setUpFromPhone`).
    func start(perform: @escaping TVSetupHandler.Perform) {
        guard task == nil else { return }
        status = .starting
        task = Task { [weak self] in
            await self?.run(perform: perform)
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        listener?.stop()
        listener = nil
        handler = nil
    }

    private func run(perform: @escaping TVSetupHandler.Perform) async {
        guard let host = Self.lanIPv4() else {
            status = .unavailable
            return
        }
        var nonce = TVSetupNonce.make()
        let handler = TVSetupHandler(nonce: nonce, perform: perform)
        let listener = TVSetupListener(handler: handler, host: host)
        self.handler = handler
        self.listener = listener
        let port: UInt16
        do {
            port = try await listener.start()
        } catch {
            guard !Task.isCancelled else { return }
            listener.stop()
            status = .unavailable
            return
        }
        guard !Task.isCancelled else { return }
        while !Task.isCancelled {
            status = .ready(url: TVSetupLink.url(host: host, port: port, nonce: nonce.value))
            // The nonce lives 10 minutes: a TV left on this screen shows a fresh code.
            try? await Task.sleep(for: .seconds(TVSetupNonce.lifetime - 5))
            guard !Task.isCancelled else { return }
            nonce = TVSetupNonce.make()
            await handler.renew(nonce)
        }
    }

    /// The Apple TV's private IPv4 on Wi-Fi or Ethernet (`en*` first), if it has one.
    static func lanIPv4() -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        var found: [(name: String, address: String)] = []
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            let flags = Int32(entry.ifa_flags)
            guard let socket = entry.ifa_addr, socket.pointee.sa_family == UInt8(AF_INET),
                  flags & IFF_UP != 0, flags & IFF_RUNNING != 0, flags & IFF_LOOPBACK == 0
            else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(socket, socklen_t(socket.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let address = String(cString: host)
            guard LocalAddress.isPrivateIPv4(address) else { continue }
            found.append((String(cString: entry.ifa_name), address))
        }
        // Wi-Fi/Ethernet before VPNs and bridges; a link-local 169.254 address last.
        let ranked = found.sorted { a, b in
            func rank(_ x: (name: String, address: String)) -> Int {
                (x.name.hasPrefix("en") ? 0 : 2) + (x.address.hasPrefix("169.254.") ? 1 : 0)
            }
            return (rank(a), a.name) < (rank(b), b.name)
        }
        return ranked.first?.address
    }
}
