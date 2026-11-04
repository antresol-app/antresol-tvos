import Foundation

/// Lenient field access used by the model decoders.
///
/// The server omits empty optional fields and may add new ones over time. Models
/// therefore decode every non-identifying field with a fallback, so a missing or
/// unexpectedly typed value degrades to a sensible default instead of failing the
/// whole response. Identifiers are still decoded strictly.
extension KeyedDecodingContainer {
    func value<T: Decodable>(_ key: Key, default fallback: @autoclosure () -> T) -> T {
        (try? decodeIfPresent(T.self, forKey: key)) ?? fallback()
    }

    func optional<T: Decodable>(_ key: Key) -> T? {
        try? decodeIfPresent(T.self, forKey: key)
    }
}
