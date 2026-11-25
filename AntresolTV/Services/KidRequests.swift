import AntresolKit
import Foundation
import Observation

/// A kid profile's requests to a parent («Попросить»): what it asked for and where each stands,
/// read the first time a screen needs them and again whenever one is opened. A new answer is put
/// in at once.
@MainActor
@Observable
final class KidRequests {
    private(set) var book = KidRequestBook()
    private(set) var loaded = false
    /// The slots being asked right now.
    private(set) var asking: Set<String> = []
    /// The slots whose last ask failed (the title can be asked for again).
    private(set) var failed: Set<String> = []

    /// Reads the profile's requests once.
    func load(using appState: AppState) async {
        guard !loaded else { return }
        await refresh(using: appState)
    }

    /// Reads them again; a failed read keeps what is shown (the list is only a hint).
    func refresh(using appState: AppState) async {
        guard let client = appState.client, let list = try? await client.myRequests(), !Task.isCancelled else { return }
        book.replace(with: list)
        loaded = true
    }

    /// Asks a parent for the title (`slot`: its place in the book).
    func ask(_ ask: KidRequestAsk, slot: String, using appState: AppState) async {
        guard let client = appState.client, !asking.contains(slot) else { return }
        asking.insert(slot)
        failed.remove(slot)
        defer { asking.remove(slot) }
        do {
            book.put(try await client.askRequest(ask))
        } catch let error as APIError where error.statusCode == 403 && error.code == "rating" {
            // above the profile's age limit: the server's own words stay with the title
            book.block(slot: slot, because: error.serverMessage ?? String(localized: "Not available for this profile", bundle: .localized))
        } catch {
            _ = appState.message(for: error)
            failed.insert(slot)
        }
    }

    /// The profile left: nothing of it stays.
    func reset() {
        book = KidRequestBook()
        loaded = false
        asking = []
        failed = []
    }
}
