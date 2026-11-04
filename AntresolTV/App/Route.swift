import AntresolKit
import SwiftUI

/// Navigation destinations pushed inside a tab's `NavigationStack`.
enum Route: Hashable {
    /// The detail page of a library card (movie, series, episode, album, book...).
    case item(Card)
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
}
