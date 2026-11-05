import AntresolKit
import SwiftUI

/// Navigation destinations pushed inside a tab's `NavigationStack`.
enum Route: Hashable {
    /// The detail page of a library card (movie, series, episode, album, book...).
    case item(Card)
    /// The detail page of an item opened from outside the app (Top Shelf, URL scheme);
    /// it takes the focus from the tab bar.
    case linkedItem(Card)
    /// The albums of a music genre.
    case genre(String)
    /// Everything in a Home shelf (its title's "See All").
    case shelf(id: String, title: String)
}

/// Pushes a route onto the current tab's navigation stack, for places that cannot use a
/// `NavigationLink` (context-menu actions).
struct OpenRouteAction {
    private let handler: (Route) -> Void

    init(_ handler: @escaping (Route) -> Void) {
        self.handler = handler
    }

    func callAsFunction(_ route: Route) {
        handler(route)
    }
}

extension EnvironmentValues {
    @Entry var openRoute = OpenRouteAction { _ in }
    /// Whether a page should move focus to its main action when it appears, even though
    /// focus is elsewhere (set for `Route.linkedItem`).
    @Entry var claimsFocusOnAppear = false
}
