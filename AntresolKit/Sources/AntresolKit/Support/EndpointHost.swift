#if canImport(Network)
import Network

extension NWEndpoint.Host {
    /// The address or name as text ("" for a host kind this does not know).
    public var text: String {
        switch self {
        case .ipv4(let address): return "\(address)"
        case .ipv6(let address): return "\(address)"
        case .name(let name, _): return name
        @unknown default: return ""
        }
    }
}
#endif
