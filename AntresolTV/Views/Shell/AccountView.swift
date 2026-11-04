import AntresolKit
import SwiftUI

/// The profile tab: who is signed in, which server, and the session actions.
struct AccountView: View {
    let user: User

    @Environment(AppState.self) private var appState
    @State private var isConfirmingSignOut = false

    var body: some View {
        HStack(alignment: .center, spacing: 140) {
            VStack(spacing: 30) {
                AvatarView(user: user, size: 280)
                Text(verbatim: user.name)
                    .font(Theme.Typography.pageTitle)
                    .foregroundStyle(Theme.Colors.label)
                Text(role)
                    .font(Theme.Typography.meta)
                    .foregroundStyle(Theme.Colors.label2)
            }
            .frame(width: 560)

            VStack(alignment: .leading, spacing: 44) {
                if let server = appState.server {
                    VStack(alignment: .leading, spacing: 18) {
                        InfoRow(title: "Server", value: server.displayName)
                        InfoRow(title: "Server version", value: server.version)
                    }
                }
                VStack(alignment: .leading, spacing: 28) {
                    Button {
                        appState.switchProfile()
                    } label: {
                        Label("Switch Profile", systemImage: "person.2")
                    }
                    Button {
                        appState.changeServer()
                    } label: {
                        Label("Change Server", systemImage: "server.rack")
                    }
                    Button {
                        isConfirmingSignOut = true
                    } label: {
                        Label("Sign Out", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                }
                .buttonStyle(PillButtonStyle(kind: .glass))
                .focusSection()
            }
            .frame(width: 760, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .confirmationDialog("Sign out of this profile?", isPresented: $isConfirmingSignOut, titleVisibility: .visible) {
            Button("Sign Out", role: .destructive) {
                Task { await appState.signOut() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You can sign in again from the profile picker.")
        }
    }

    private var role: LocalizedStringKey {
        if user.isAdmin { return "Administrator" }
        if user.isKid {
            if let rating = user.maxRating, !rating.isEmpty {
                return "Kid profile · up to \(rating)"
            }
            return "Kid profile"
        }
        return "Profile"
    }
}

private struct InfoRow: View {
    let title: LocalizedStringKey
    let value: String

    var body: some View {
        HStack(spacing: 20) {
            Text(title)
                .foregroundStyle(Theme.Colors.label3)
            Text(verbatim: value)
                .foregroundStyle(Theme.Colors.label)
        }
        .font(Theme.Typography.meta)
    }
}
