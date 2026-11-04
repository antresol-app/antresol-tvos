import SwiftUI

@main
struct AntresolTVApp: App {
    @State private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appState)
                .preferredColorScheme(.dark)
                .task { await appState.bootstrap() }
        }
    }
}
