import SwiftUI

/// Chooses the top-level screen for the current session phase.
struct RootView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        ZStack {
            Theme.Colors.background.ignoresSafeArea()
            switch appState.phase {
            case .launching:
                SplashView(status: nil, isWorking: true)
            case .serverUnreachable:
                SplashView(
                    status: "The server is not responding",
                    isWorking: false,
                    retry: { Task { await appState.bootstrap() } },
                    changeServer: { appState.changeServer() }
                )
            case .needsServer:
                ServerEntryView()
            case .needsProfile:
                ProfilePickerView()
            case .signedIn(let user):
                MainShellView(user: user)
                    // A different profile gets a fresh shell (tabs, stacks, loaded data).
                    .id(user.id)
            }
        }
        .animation(Theme.Motion.easeOut, value: appState.phase)
    }
}
