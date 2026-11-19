import SwiftUI

@main
struct AntresolTVApp: App {
    @State private var appState = AppState()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appState)
                .environment(\.locale, appState.language.locale)
                .preferredColorScheme(.dark)
                .task { await appState.bootstrap() }
                .onOpenURL { appState.open($0) }
                // Back from the home screen or standby: the profile (its photo) may have changed.
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { Task { await appState.refreshUser() } }
                }
        }
    }
}
