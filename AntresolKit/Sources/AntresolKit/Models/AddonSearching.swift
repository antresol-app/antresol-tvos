import Foundation

/// The addons' own searches of the Search tab, asked all at once for one query.
public enum AddonSearching {
    /// The sections found so far, as a snapshot each time an addon that found titles answers: one
    /// section per addon that found something, always in the order of `searches` (not of the
    /// answers), under the heading the addon names. An addon that fails or finds nothing has no
    /// section and no snapshot of its own, and no word is said. The stream ends when every addon
    /// has answered; a consumer that stops reading (or is cancelled) cancels the questions still
    /// out.
    public static func sections(
        for searches: [AddonSearch],
        ask: @escaping @Sendable (AddonSearch) async throws -> [AddonTitle]
    ) -> AsyncStream<[AddonSearchSection]> {
        AsyncStream { continuation in
            let task = Task {
                var found: [String: [AddonTitle]] = [:]
                await withTaskGroup(of: (String, [AddonTitle]?).self) { group in
                    for search in searches {
                        group.addTask { (search.addonId, try? await ask(search)) }
                    }
                    for await (addon, titles) in group {
                        guard let titles, !titles.isEmpty else { continue }
                        found[addon] = titles
                        continuation.yield(searches.compactMap { search in
                            found[search.addonId].map { AddonSearchSection(addonId: search.addonId, label: search.label, titles: $0) }
                        })
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
