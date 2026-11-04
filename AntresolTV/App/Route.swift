import AntresolKit

/// Navigation destinations pushed inside a tab's `NavigationStack`.
enum Route: Hashable {
    /// The detail page of a library card (movie, series, episode, album, book...).
    case item(Card)
}
