import SwiftUI

@main
struct AntresolTVApp: App {
    @State private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appState)
                .environment(\.locale, appState.language.locale)
                .preferredColorScheme(.dark)
                .task { await appState.bootstrap() }
                .onOpenURL { appState.open($0) }
        }
    }
}
