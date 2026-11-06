import AntresolKit
import Foundation

extension ItemKind {
    /// Localized singular name, e.g. "Movie" / "Фильм". Empty for other kinds.
    var displayName: String {
        switch self {
        case .movie: return String(localized: "Movie", bundle: .localized)
        case .series: return String(localized: "Series", bundle: .localized)
        case .season: return String(localized: "Season", bundle: .localized)
        case .episode: return String(localized: "Episode", bundle: .localized)
        case .artist: return String(localized: "Artist", bundle: .localized)
        case .album: return String(localized: "Album", bundle: .localized)
        case .playlist: return String(localized: "Playlist", bundle: .localized)
        default: return ""
        }
    }
}
