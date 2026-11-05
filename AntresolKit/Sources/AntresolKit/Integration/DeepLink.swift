import Foundation

/// App URLs (`antresol://…`) used by the Top Shelf and other system entry points.
///
/// - `antresol://item/{id}` opens the item's page.
/// - `antresol://play/{id}` starts the item (resuming where it was left).
public enum DeepLink: Hashable, Sendable {
    case item(id: Int)
    case play(id: Int)

    public static let scheme = "antresol"

    public init?(url: URL) {
        guard url.scheme?.lowercased() == Self.scheme,
              let host = url.host?.lowercased()
        else { return nil }
        let components = url.pathComponents.filter { $0 != "/" }
        guard components.count == 1, let id = Int(components[0]), id > 0 else { return nil }
        switch host {
        case "item": self = .item(id: id)
        case "play": self = .play(id: id)
        default: return nil
        }
    }

    public var url: URL {
        switch self {
        case .item(let id): return URL(string: "\(Self.scheme)://item/\(id)")!
        case .play(let id): return URL(string: "\(Self.scheme)://play/\(id)")!
        }
    }

    public var itemId: Int {
        switch self {
        case .item(let id), .play(let id): return id
        }
    }
}
