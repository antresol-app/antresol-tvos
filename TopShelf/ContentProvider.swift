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
        async let channelList = try? ChannelService(client: client).list()
        guard let home = try? await client.home() else { return nil }
        let plan = TopShelfPlan(home: home)
        let live = TopShelfChannels(channels: await channelList?.channels ?? [], at: Date())
        guard !plan.sections.isEmpty || !live.entries.isEmpty else { return nil }

        let strings = stringsBundle(for: stored.session.language)
        let artwork = TopShelfArtwork(client: client)
        artwork.removeExpiredFiles()
        // Each picture at the width of its tile (a path in two shapes at the wider one).
        var widths: [String: Int] = [:]
        func want(_ path: String, _ shape: TopShelfPlan.Shape) {
            widths[path] = max(widths[path] ?? 0, TopShelfArtwork.width(for: shape))
        }
        for section in plan.sections {
            for path in section.entries.compactMap(\.imagePath) { want(path, section.shape) }
        }
        for path in live.entries.map(\.imagePath) where !path.isEmpty { want(path, .wide) }
        var files = await artwork.files(for: widths)
        // A tile whose best picture failed (an episode frame while the server is busy) gets
        // its next one.
        widths = [:]
        for section in plan.sections {
            for entry in section.entries where entry.imagePaths.first(where: { files[$0] != nil }) == nil {
                if let path = entry.imagePaths.dropFirst().first { want(path, section.shape) }
            }
        }
        if !widths.isEmpty {
            files.merge(await artwork.files(for: widths)) { current, _ in current }
        }
        let placeholder = live.entries.contains { files[$0.imagePath] == nil } ? artwork.placeholderFile() : nil

        var collections = plan.sections.map { section in
            let items = section.entries.map { entry in
                let item = TVTopShelfSectionedItem(identifier: entry.card.uniqueKey)
                item.title = entry.card.title
                item.imageShape = section.shape == .wide ? .hdtv : .poster
                if let file = entry.imagePaths.lazy.compactMap({ files[$0] }).first {
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
            collection.title = title(for: section, strings: strings)
            return collection
        }
        if !live.entries.isEmpty {
            // After Continue Watching, before Recently Added.
            let index = plan.sections.first?.kind == .continueWatching ? 1 : 0
            collections.insert(liveCollection(live, files: files, placeholder: placeholder, strings: strings), at: index)
        }
        return TVTopShelfSectionedContent(sections: collections)
    }

    /// «Сейчас в эфире»: the programme's still (else the neutral placeholder), "10 ·
    /// Comedies — Title" and how far it is.
    private static func liveCollection(_ live: TopShelfChannels, files: [String: URL], placeholder: URL?, strings: Bundle) -> TVTopShelfItemCollection<TVTopShelfSectionedItem> {
        let items = live.entries.map { entry in
            let item = TVTopShelfSectionedItem(identifier: "channel-\(entry.channel.id)")
            item.title = entry.title
            item.imageShape = .hdtv
            if let file = files[entry.imagePath] ?? placeholder {
                item.setImageURL(file, for: [.screenScale1x, .screenScale2x])
            }
            item.playbackProgress = entry.progress
            item.displayAction = TVTopShelfAction(url: entry.url)
            item.playAction = TVTopShelfAction(url: entry.url)
            return item
        }
        let collection = TVTopShelfItemCollection(items: items)
        collection.title = String(localized: "On Air Now", bundle: strings)
        return collection
    }

    private static func title(for section: TopShelfPlan.Section, strings: Bundle) -> String {
        if let serverTitle = section.serverTitle { return serverTitle }
        switch section.kind {
        case .continueWatching: return String(localized: "Continue Watching", bundle: strings)
        case .recentlyAdded: return String(localized: "Recently Added", bundle: strings)
        }
    }

    /// The strings of the app's language (`en` or `ru`, as the session has it), which the
    /// server's titles are in too; the system's language when it has no strings of its own.
    private static func stringsBundle(for language: String) -> Bundle {
        Bundle.main.path(forResource: language, ofType: "lproj").flatMap(Bundle.init(path:)) ?? .main
    }
}
