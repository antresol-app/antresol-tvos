import AntresolKit
import SwiftUI

/// First-run screen: pick a server found on the home network (Bonjour), or enter its
/// address. Accepts a host, `host:port` or a full http(s) URL (port 8420 by default) and
/// checks it with `/api/health` before continuing; a found server connects the same way.
///
/// Opened from Settings while signed in, it is presented over the shell with `close`: the
/// signed-in session (tabs, playback) is untouched until another server connects.
struct ServerEntryView: View {
    /// Dismisses the screen when it was presented over a signed-in session.
    var close: (() -> Void)?

    @Environment(AppState.self) private var appState
    @State private var browser = ServerBrowser()
    @State private var address = ""
    @State private var isConnecting = false
    /// The found server being connected to (its row shows the progress).
    @State private var connectingServerId: String?
    @State private var errorMessage: String?
    /// Bonjour has had a few seconds without finding anything.
    @State private var searchSettled = false
    @FocusState private var focus: Field?

    private enum Field: Hashable {
        case server(String)
        case address
        case connect
    }

    /// How long "Looking for servers…" shows before the "none found" hint.
    private static let searchPatience: Duration = .seconds(5)
    /// The list keeps the screen's height in check; more servers than this are rare.
    private static let maxServers = 4

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
                    Text("Choose a server found on your network, or enter the address of the computer running Antresol, for example 192.168.1.10 or nas.local. The port defaults to 8420.")
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.Colors.label2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(width: 720, alignment: .leading)

                VStack(alignment: .leading, spacing: 48) {
                    discovered
                    manualEntry
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
            browser.start()
        }
        .onDisappear { browser.stop() }
        .task {
            try? await Task.sleep(for: Self.searchPatience)
            searchSettled = true
        }
        .onChange(of: browser.servers) { old, servers in
            // The first server found takes the focus from the empty field, so a single
            // press of Select connects; a field with an address keeps it.
            guard old.isEmpty, trimmedAddress.isEmpty, focus == .address || focus == nil, let first = servers.first else { return }
            focus = .server(first.id)
        }
        .onExitCommand(perform: canCancel ? cancel : nil)
    }

    // MARK: Found on the network

    @ViewBuilder
    private var discovered: some View {
        let servers = Array(browser.servers.prefix(Self.maxServers))
        SettingsSection("On This Network") {
            if servers.isEmpty {
                searchStatus
            } else {
                ForEach(servers) { server in
                    Button {
                        connect(to: server)
                    } label: {
                        DiscoveredServerLabel(server: server, isConnecting: connectingServerId == server.id)
                    }
                    .focused($focus, equals: .server(server.id))
                    .disabled(isConnecting)
                }
            }
        }
    }

    /// What the list says while it has no server: searching, nothing found (with the
    /// Docker caveat), or local network access turned off.
    @ViewBuilder
    private var searchStatus: some View {
        Group {
            if browser.isDenied {
                Label {
                    Text("Antresol can't look for servers: local network access is off. Turn it on in Settings > Privacy & Security > Local Network, or enter the address below.")
                } icon: {
                    Image(systemName: "network.slash")
                }
            } else if !searchSettled {
                HStack(spacing: 20) {
                    ProgressView()
                    Text("Looking for servers…")
                }
            } else {
                Label {
                    Text("No servers found. A server in Docker is found only with host networking: enter its address below.")
                } icon: {
                    Image(systemName: "magnifyingglass")
                }
            }
        }
        .font(Theme.Typography.meta)
        .foregroundStyle(Theme.Colors.label2)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, minHeight: 92, alignment: .leading)
    }

    // MARK: Address

    private var manualEntry: some View {
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
        if isConnecting && connectingServerId == nil {
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
        connect(address: trimmedAddress, serverId: nil)
    }

    /// A found server connects exactly as if its address had been typed.
    private func connect(to server: DiscoveredServer) {
        guard !isConnecting else { return }
        connect(address: server.baseURL.absoluteString, serverId: server.id)
    }

    private func connect(address: String, serverId: String?) {
        isConnecting = true
        connectingServerId = serverId
        errorMessage = nil
        Task {
            do {
                try await appState.connect(to: address)
                close?()
            } catch {
                errorMessage = Self.describe(error)
                focus = serverId.map(Field.server) ?? .address
            }
            isConnecting = false
            connectingServerId = nil
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

/// A server found on the network: its name, then address and version, on a settings row.
private struct DiscoveredServerLabel: View {
    let server: DiscoveredServer
    let isConnecting: Bool

    var body: some View {
        HStack(spacing: 28) {
            Image(systemName: "server.rack")
                .font(.system(size: 30, weight: .semibold))
                .frame(width: 44)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: server.name)
                    .lineLimit(1)
                Text("Antresol \(server.version) · \(server.address)")
                    .font(Theme.Typography.cardMeta)
                    .lineLimit(1)
                    .opacity(0.7)
            }
            Spacer(minLength: 24)
            if isConnecting {
                ProgressView()
            } else {
                Image(systemName: "chevron.right")
                    .font(.system(size: 26, weight: .semibold))
                    .opacity(0.5)
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, 14)
        .accessibilityElement(children: .combine)
    }
}

#Preview {
    ServerEntryView()
        .environment(AppState())
}
