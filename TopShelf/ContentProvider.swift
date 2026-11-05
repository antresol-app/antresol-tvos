import AntresolKit
import Foundation
import TVServices

/// Fills the Top Shelf with the signed-in profile's Continue Watching row and the newest
/// movies and shows. Selecting a tile opens `antresol://item/{id}`; Play opens
/// `antresol://play/{id}`. With no shared session (signed out) the static brand image shows.
final class ContentProvider: TVTopShelfContentProvider {
    override func loadTopShelfContent(completionHandler: @escaping (TVTopShelfContent?) -> Void) {
        Task {
            completionHandler(await Self.makeContent())
        }
    }

    private static func makeContent() async -> TVTopShelfContent? {
        guard let stored = SharedSessionStore.load() else { return nil }
        let client = APIClient(baseURL: stored.session.serverURL, token: stored.token, language: stored.session.language)
        guard let home = try? await client.home() else { return nil }
        let plan = TopShelfPlan(home: home)
        guard !plan.sections.isEmpty else { return nil }

        let artwork = TopShelfArtwork(client: client)
        let paths = plan.sections.flatMap { $0.entries.compactMap(\.imagePath) }
        let files = await artwork.files(for: paths)

        let collections = plan.sections.map { section in
            let items = section.entries.map { entry in
                let item = TVTopShelfSectionedItem(identifier: entry.card.uniqueKey)
                item.title = entry.card.title
                item.imageShape = section.shape == .wide ? .hdtv : .poster
                if let path = entry.imagePath, let file = files[path] {
                    item.setImageURL(file, for: [.screenScale1x, .screenScale2x])
                }
                if let progress = entry.progress {
                    item.playbackProgress = progress
                }
                item.displayAction = TVTopShelfAction(url: entry.displayURL)
                if let playURL = entry.playURL {
                    item.playAction = TVTopShelfAction(url: playURL)
                }
                return item
            }
            let collection = TVTopShelfItemCollection(items: items)
            collection.title = title(for: section)
            return collection
        }
        return TVTopShelfSectionedContent(sections: collections)
    }

    private static func title(for section: TopShelfPlan.Section) -> String {
        if let serverTitle = section.serverTitle { return serverTitle }
        switch section.kind {
        case .continueWatching: return String(localized: "Continue Watching")
        case .recentlyAdded: return String(localized: "Recently Added")
        }
    }
}
