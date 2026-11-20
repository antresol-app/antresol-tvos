import Foundation

/// The ways and searches the signed-in profile's addons offer the apps, found once and kept for
/// the session: `GET /api/addons/web` names the open addons, and each one's `GET x/app` says what it
/// offers. An addon that answers `404`, `403`, an unreadable body or another protocol version
/// offers nothing; so does a server without addons or a kid's profile (`403`), silently.
///
/// One catalog serves one signed-in client; a new profile or server gets a new one, and
/// `invalidate()` makes the next `snapshot()` look again (the Home tab's refresh).
public actor AddonCatalog {
    /// How long a result that missed something (a busy server, a dropped connection) is kept
    /// before the next `snapshot()` asks again.
    public static let incompleteRetry: TimeInterval = 60

    private struct Discovery: Sendable {
        var snapshot: AddonCatalogSnapshot
        /// Every answer was a definite one (not a timeout or a server error).
        var complete: Bool
    }

    private enum Outcome: Sendable {
        case info(AppInfo)
        case none
        case transient
    }

    private let client: APIClient
    private let now: @Sendable () -> Date
    private var cached: (discovery: Discovery, at: Date)?
    private var loading: Task<Discovery, Never>?
    /// Bumped by `invalidate()`: a load that started before it must not fill the cache.
    private var epoch = 0

    public init(client: APIClient, now: @escaping @Sendable () -> Date = { Date() }) {
        self.client = client
        self.now = now
    }

    /// What the addons offer, from the cache when it is current.
    public func snapshot() async -> AddonCatalogSnapshot {
        if let cached, cached.discovery.complete || now().timeIntervalSince(cached.at) < Self.incompleteRetry {
            return cached.discovery.snapshot
        }
        if let loading {
            return await loading.value.snapshot
        }
        let started = epoch
        let client = self.client
        let task = Task { await Self.discover(client) }
        loading = task
        let discovery = await task.value
        if epoch == started {
            cached = (discovery, now())
            loading = nil
        }
        return discovery.snapshot
    }

    /// Forgets what was found: the next `snapshot()` looks again.
    public func invalidate() {
        epoch += 1
        cached = nil
        loading?.cancel()
        loading = nil
    }

    private static func discover(_ client: APIClient) async -> Discovery {
        let ids: [String]
        do {
            ids = try await client.openAddonIds()
        } catch {
            return Discovery(snapshot: .empty, complete: isDefinite(error))
        }
        var unique = Set<String>()
        let addons = ids.filter { unique.insert($0).inserted }
        var infos: [(addonId: String, info: AppInfo)] = []
        var complete = true
        await withTaskGroup(of: (String, Outcome).self) { group in
            for id in addons {
                group.addTask {
                    do {
                        return (id, .info(try await client.appInfo(addon: id)))
                    } catch {
                        return (id, isDefinite(error) ? .none : .transient)
                    }
                }
            }
            for await (id, outcome) in group {
                switch outcome {
                case .info(let info): infos.append((id, info))
                case .none: break
                case .transient: complete = false
                }
            }
        }
        return Discovery(snapshot: AddonCatalogSnapshot.merging(infos), complete: complete)
    }

    /// A refusal or an unreadable answer will not change by asking again; a timeout, a dropped
    /// connection or a server error might.
    private static func isDefinite(_ error: Error) -> Bool {
        guard let error = error as? APIError else { return false }
        switch error {
        case .decoding, .invalidURL: return true
        case .unauthorized: return true
        case .server(let status, _, _, _): return (400..<500).contains(status)
        case .transport: return false
        }
    }
}
