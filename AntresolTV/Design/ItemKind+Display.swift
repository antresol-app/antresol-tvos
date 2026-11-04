import AntresolKit
import Foundation

extension ItemKind {
    /// Localized singular name, e.g. "Movie" / "Фильм". Empty for unknown kinds.
    var displayName: String {
        switch self {
        case .movie: return String(localized: "Movie")
        case .series: return String(localized: "Series")
        case .season: return String(localized: "Season")
        case .episode: return String(localized: "Episode")
        case .artist: return String(localized: "Artist")
        case .album: return String(localized: "Album")
        case .playlist: return String(localized: "Playlist")
        case .audiobook: return String(localized: "Audiobook")
        case .book: return String(localized: "Book")
        case .comic: return String(localized: "Comic")
        case .comicVolume: return String(localized: "Comic Volume")
        default: return ""
        }
    }
}
