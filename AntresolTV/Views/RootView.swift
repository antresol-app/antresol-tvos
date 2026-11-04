import SwiftUI

/// Chooses the top-level screen for the current session phase.
struct RootView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        ZStack {
            Theme.Colors.background.ignoresSafeArea()
            SplashView(status: status, isWorking: appState.phase == .launching, retry: retry)
        }
    }

    private var retry: (() -> Void)? {
        guard case .serverUnreachable = appState.phase else { return nil }
        return { Task { await appState.bootstrap() } }
    }

    private var status: LocalizedStringKey? {
        switch appState.phase {
        case .launching:
            return nil
        case .needsServer:
            return "No server configured"
        case .serverUnreachable:
            return "The server is not responding"
        case .needsProfile:
            return "Choose a profile"
        case .signedIn(let user):
            return "Signed in as \(user.name)"
        }
    }
}
