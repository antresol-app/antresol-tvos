import SwiftUI

/// Chooses the top-level screen for the current session phase.
struct RootView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        ZStack {
            Theme.Colors.background.ignoresSafeArea()
            // The signed-in shell, kept alive under the picker «Switch Profile» opens, so Menu
            // there returns to where the user was (tab, page, what plays).
            if let user = appState.shellUser {
                let picking = appState.currentUser == nil
                MainShellView(user: user)
                    // A different profile gets a fresh shell (tabs, stacks, loaded data), and
                    // so does another «Отдельная история» of this device: every page shows
                    // that history's progress and Continue Watching.
                    .id(ShellIdentity(userId: user.id, historyId: user.deviceHistory?.id))
                    .opacity(picking ? 0 : 1)
                    .disabled(picking)
                    .accessibilityHidden(picking)
            }
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
                if appState.signInMethod == .phone && appState.supportsPairing {
                    PairingView()
                        .transition(.opacity)
                } else {
                    ProfilePickerView()
                        .transition(.opacity)
                }
            case .signedIn:
                EmptyView()
            }
        }
        .animation(Theme.Motion.easeOut, value: appState.phase)
        .animation(Theme.Motion.easeOut, value: appState.signInMethod)
    }
}

/// Whose data the signed-in shell shows: the profile, and the separate history this device
/// writes into (nil: the profile's own).
private struct ShellIdentity: Hashable {
    let userId: Int
    let historyId: Int?
}
