import AntresolKit
import Foundation
import TVServices

/// Fills the Top Shelf with the signed-in profile's Continue Watching row, the live
/// channels on air and the newest movies and shows. Selecting a tile opens
/// `antresol://item/{id}`; Play opens `antresol://play/{id}`; a channel opens
/// `antresol://channel/{id}`, its live player. With no shared session (signed out) the
/// static brand image shows.
final class ContentProvider: TVTopShelfContentProvider {
    override func loadTopShelfContent(completionHandler: @escaping (TVTopShelfContent?) -> Void) {
        Task {
            completionHandler(await Self.makeContent())
        }
    }

    private static func makeContent() async -> TVTopShelfContent? {
        guard let stored = SharedSessionStore.load() else { return nil }
        let client = APIClient(baseURL: stored.session.serverURL, token: stored.token, language: stored.session.language)
        // A server without channels (or a failed list) just leaves the section out.
        async let channelList = try? client.channels()
        guard let home = try? await client.home() else { return nil }
        let plan = TopShelfPlan(home: home)
        let live = TopShelfChannels(channels: await channelList?.channels ?? [], at: Date())
        guard !plan.sections.isEmpty || !live.entries.isEmpty else { return nil }

        let artwork = TopShelfArtwork(client: client)
        let paths = plan.sections.flatMap { $0.entries.compactMap(\.imagePath) } + live.entries.map(\.imagePath)
        let files = await artwork.files(for: paths)

        var collections = plan.sections.map { section in
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
        if !live.entries.isEmpty {
            // After Continue Watching, before Recently Added.
            let index = plan.sections.first?.kind == .continueWatching ? 1 : 0
            collections.insert(liveCollection(live, files: files), at: index)
        }
        return TVTopShelfSectionedContent(sections: collections)
    }

    /// «Сейчас в эфире»: the programme's art, "10 · Comedies — Title" and how far it is.
    private static func liveCollection(_ live: TopShelfChannels, files: [String: URL]) -> TVTopShelfItemCollection<TVTopShelfSectionedItem> {
        let items = live.entries.map { entry in
            let item = TVTopShelfSectionedItem(identifier: "channel-\(entry.channel.id)")
            item.title = entry.title
            item.imageShape = .hdtv
            if let file = files[entry.imagePath] {
                item.setImageURL(file, for: [.screenScale1x, .screenScale2x])
            }
            item.playbackProgress = entry.progress
            item.displayAction = TVTopShelfAction(url: entry.url)
            item.playAction = TVTopShelfAction(url: entry.url)
            return item
        }
        let collection = TVTopShelfItemCollection(items: items)
        collection.title = String(localized: "On Air Now")
        return collection
    }

    private static func title(for section: TopShelfPlan.Section) -> String {
        if let serverTitle = section.serverTitle { return serverTitle }
        switch section.kind {
        case .continueWatching: return String(localized: "Continue Watching")
        case .recentlyAdded: return String(localized: "Recently Added")
        }
    }
}
