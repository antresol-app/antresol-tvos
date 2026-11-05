import AntresolKit
import SwiftUI

/// Password prompt for a protected profile.
struct PasswordEntryView: View {
    let profile: Profile
    let onCancel: () -> Void

    @Environment(AppState.self) private var appState
    @State private var password = ""
    @State private var isSigningIn = false
    @State private var errorMessage: String?
    @FocusState private var isFieldFocused: Bool

    var body: some View {
        VStack(spacing: 44) {
            AvatarView(profile: profile, size: 200)
            VStack(spacing: 14) {
                Text(verbatim: profile.name)
                    .font(Theme.Typography.pageTitle)
                    .foregroundStyle(Theme.Colors.label)
                Text("Enter the password for this profile")
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Colors.label2)
            }
            SecureField("Password", text: $password)
                .textContentType(.password)
                .focused($isFieldFocused)
                .submitLabel(.go)
                .onSubmit(signIn)
                .disabled(isSigningIn)
                .frame(width: 760)

            Group {
                if isSigningIn {
                    ProgressView()
                } else if let errorMessage {
                    ErrorLine(message: errorMessage)
                }
            }
            .frame(minHeight: 44)

            HStack(spacing: 28) {
                Button(action: signIn) {
                    Label("Sign In", systemImage: "arrow.right")
                }
                .buttonStyle(PillButtonStyle(kind: .primary))
                .disabled(password.isEmpty || isSigningIn)

                Button("Cancel", action: onCancel)
                    .buttonStyle(PillButtonStyle(kind: .glass))
            }
            .focusSection()
        }
        .padding(.horizontal, Theme.Layout.margin)
        .onAppear { isFieldFocused = true }
        .onExitCommand(perform: onCancel)
    }

    private func signIn() {
        guard !password.isEmpty, !isSigningIn else { return }
        isSigningIn = true
        errorMessage = nil
        Task {
            do {
                try await appState.signIn(profile: profile, password: password)
            } catch {
                errorMessage = AppState.userMessage(for: error)
                password = ""
                isFieldFocused = true
            }
            isSigningIn = false
        }
    }
}
