import AntresolKit
import SwiftUI

/// "Who's watching?": the profiles from `GET /api/profiles` as avatar tiles. Protected
/// profiles show a lock and ask for their password.
struct ProfilePickerView: View {
    @Environment(AppState.self) private var appState
    @State private var profiles: [Profile] = []
    @State private var loadError: String?
    @State private var isLoading = true
    @State private var signInError: String?
    @State private var busyProfileId: Int?
    @State private var passwordProfile: Profile?

    var body: some View {
        ZStack {
            OnboardingBackground()
            if let profile = passwordProfile {
                PasswordEntryView(profile: profile) {
                    passwordProfile = nil
                }
                .transition(.opacity)
            } else {
                picker
                    .transition(.opacity)
            }
        }
        .animation(Theme.Motion.easeOut, value: passwordProfile)
        .task { await load() }
    }

    private var picker: some View {
        VStack(spacing: 64) {
            VStack(spacing: 20) {
                BrandMark(size: 56)
                Text("Who's watching?")
                    .font(Theme.Typography.pageTitle)
                    .foregroundStyle(Theme.Colors.label)
            }

            content
                .frame(minHeight: 380)

            VStack(spacing: 28) {
                if let server = appState.server {
                    Text("Antresol \(server.version) · \(server.displayName)")
                        .font(Theme.Typography.meta)
                        .foregroundStyle(Theme.Colors.label3)
                }
                Button {
                    appState.changeServer()
                } label: {
                    Label("Change Server", systemImage: "server.rack")
                }
                .buttonStyle(PillButtonStyle(kind: .glass))
            }
            .focusSection()
        }
        .padding(.horizontal, Theme.Layout.margin)
    }

    @ViewBuilder
    private var content: some View {
        if isLoading && profiles.isEmpty {
            ProgressView()
        } else if let loadError, profiles.isEmpty {
            VStack(spacing: 32) {
                ErrorLine(message: loadError)
                Button("Try Again") { Task { await load() } }
                    .buttonStyle(PillButtonStyle(kind: .primary))
            }
        } else if profiles.isEmpty {
            Text("This server has no profiles yet. Create one in the Antresol web app.")
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Colors.label2)
                .multilineTextAlignment(.center)
        } else {
            VStack(spacing: 40) {
                LazyVGrid(columns: columns, spacing: 56) {
                    ForEach(profiles) { profile in
                        Button {
                            select(profile)
                        } label: {
                            ProfileTile(profile: profile, isBusy: busyProfileId == profile.id)
                        }
                        .buttonStyle(CardButtonStyle())
                        .disabled(busyProfileId != nil)
                    }
                }
                .frame(maxWidth: .infinity)
                .focusSection()
                if let signInError {
                    ErrorLine(message: signInError)
                }
            }
        }
    }

    private var columns: [GridItem] {
        let count = min(max(profiles.count, 1), 6)
        return Array(repeating: GridItem(.fixed(ProfileTile.width), spacing: 64), count: count)
    }

    private func load() async {
        guard let client = appState.client else { return }
        isLoading = true
        do {
            profiles = try await client.profiles()
            loadError = nil
        } catch {
            if !Task.isCancelled { loadError = error.localizedDescription }
        }
        isLoading = false
    }

    private func select(_ profile: Profile) {
        signInError = nil
        busyProfileId = profile.id
        Task {
            do {
                if try await appState.selectProfile(profile) == .needsPassword {
                    passwordProfile = profile
                }
            } catch {
                signInError = error.localizedDescription
            }
            busyProfileId = nil
        }
    }
}

/// An avatar with the profile name underneath; a lock marks password-protected profiles.
private struct ProfileTile: View {
    static let width: CGFloat = 240

    let profile: Profile
    let isBusy: Bool

    @Environment(\.isCardFocused) private var isFocused

    var body: some View {
        VStack(spacing: 26) {
            AvatarView(profile: profile, size: 200)
                .overlay {
                    if isBusy {
                        Circle().fill(.black.opacity(0.45))
                        ProgressView()
                    }
                }
                .overlay(
                    Circle().strokeBorder(.white.opacity(isFocused ? 0.95 : 0), lineWidth: 6)
                        .padding(-12)
                )
                .scaleEffect(isFocused ? 1.1 : 1)
                .shadow(color: .black.opacity(isFocused ? 0.6 : 0), radius: 26, y: 16)

            HStack(spacing: 10) {
                Text(verbatim: profile.name)
                    .lineLimit(1)
                if profile.hasPassword {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(Theme.Colors.label3)
                        .accessibilityLabel(Text("Password protected"))
                }
            }
            .font(Theme.Typography.headline)
            .foregroundStyle(isFocused ? Theme.Colors.label : Theme.Colors.label2)
            .offset(y: isFocused ? 10 : 0)
        }
        .frame(width: Self.width)
        .padding(.vertical, 16)
    }
}
