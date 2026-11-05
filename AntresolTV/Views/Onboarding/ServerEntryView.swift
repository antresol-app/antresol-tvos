import AntresolKit
import SwiftUI

/// First-run screen: enter the server address. Accepts a host, `host:port` or a full
/// http(s) URL (port 8420 by default) and checks it with `/api/health` before continuing.
///
/// Opened from Settings while signed in, it is presented over the shell with `close`: the
/// signed-in session (tabs, playback) is untouched until another server connects.
struct ServerEntryView: View {
    /// Dismisses the screen when it was presented over a signed-in session.
    var close: (() -> Void)?

    @Environment(AppState.self) private var appState
    @State private var address = ""
    @State private var isConnecting = false
    @State private var errorMessage: String?
    @FocusState private var focus: Field?

    private enum Field: Hashable {
        case address
        case connect
    }

    var body: some View {
        ZStack {
            OnboardingBackground()
            HStack(alignment: .center, spacing: 120) {
                VStack(alignment: .leading, spacing: 36) {
                    BrandMark()
                    Text("Connect to your server")
                        .font(Theme.Typography.pageTitle)
                        .foregroundStyle(Theme.Colors.label)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Enter the address of the computer running Antresol, for example 192.168.1.10 or nas.local. The port defaults to 8420.")
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.Colors.label2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(width: 720, alignment: .leading)

                VStack(alignment: .leading, spacing: 36) {
                    TextField("Server address", text: $address)
                        .textContentType(.URL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focus, equals: .address)
                        .submitLabel(.go)
                        .onSubmit(connect)
                        .disabled(isConnecting)

                    status
                        .frame(minHeight: 44, alignment: .leading)

                    HStack(spacing: 28) {
                        Button(action: connect) {
                            Label("Connect", systemImage: "arrow.right")
                        }
                        .buttonStyle(PillButtonStyle(kind: .primary))
                        .focused($focus, equals: .connect)
                        .disabled(isConnecting || trimmedAddress.isEmpty)

                        if canCancel {
                            Button("Cancel", action: cancel)
                                .buttonStyle(PillButtonStyle(kind: .glass))
                        }
                    }
                }
                .frame(width: 760, alignment: .leading)
                .focusSection()
            }
            .padding(.horizontal, Theme.Layout.margin)
        }
        .onAppear {
            if address.isEmpty, let server = appState.server {
                address = Self.editableAddress(for: server.url)
            }
            focus = address.isEmpty ? .address : .connect
        }
        .onExitCommand(perform: canCancel ? cancel : nil)
    }

    private var canCancel: Bool {
        close != nil || appState.canCancelServerChange
    }

    private func cancel() {
        if let close {
            close()
        } else {
            appState.cancelServerChange()
        }
    }

    @ViewBuilder
    private var status: some View {
        if isConnecting {
            HStack(spacing: 20) {
                ProgressView()
                Text("Checking server…")
                    .font(Theme.Typography.meta)
                    .foregroundStyle(Theme.Colors.label2)
            }
        } else if let errorMessage {
            ErrorLine(message: errorMessage)
        }
    }

    private var trimmedAddress: String {
        address.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func connect() {
        guard !isConnecting, !trimmedAddress.isEmpty else { return }
        guard ServerAddress.normalize(trimmedAddress) != nil else {
            errorMessage = String(localized: "That doesn't look like a server address.", bundle: .localized)
            return
        }
        isConnecting = true
        errorMessage = nil
        Task {
            do {
                try await appState.connect(to: trimmedAddress)
                close?()
            } catch {
                errorMessage = Self.describe(error)
                focus = .address
            }
            isConnecting = false
        }
    }

    /// Plain http addresses on the default port are shown the way people type them.
    private static func editableAddress(for url: URL) -> String {
        if url.scheme == "http", url.port == ServerAddress.defaultPort, url.path.isEmpty {
            return url.host ?? url.absoluteString
        }
        return url.absoluteString
    }

    private static func describe(_ error: Error) -> String {
        switch error as? APIError {
        case .transport?:
            return String(localized: "Couldn't reach the server. Check the address and that the server is running.", bundle: .localized)
        case .decoding?, .server?:
            return String(localized: "This address doesn't answer like an Antresol server.", bundle: .localized)
        default:
            return AppState.userMessage(for: error)
        }
    }
}

#Preview {
    ServerEntryView()
        .environment(AppState())
}
