import AntresolKit
import SwiftUI

/// First-run screen. "Set up with your phone" first: a QR code of this Apple TV's setup
/// endpoint (`PhoneSetup`); the Antresol app on a signed-in phone (or the phone's
/// browser) sends the server, the TV checks and saves it and moves on to sign-in by QR,
/// which the app approves at once. The remote stays a fallback: a server found on the
/// home network (Bonjour), or "Enter Address with the Remote", which shows the address
/// field (a host, `host:port` or a full http(s) URL, port 8420 by default, checked with
/// `/api/health` before continuing; a found server connects the same way).
struct ServerEntryView: View {
    @Environment(AppState.self) private var appState
    @State private var browser = ServerBrowser()
    @State private var setup = PhoneSetup()
    /// The address field is shown ("Enter Address with the Remote"); otherwise the QR code.
    @State private var entersAddress = false
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
        case enterAddress
        case address
        case connect
    }

    /// How long "Looking for servers…" shows before the "none found" hint.
    private static let searchPatience: Duration = .seconds(5)
    /// The list keeps the screen's height in check; more servers than this are rare.
    private static let maxServers = 4
    /// The QR screen's column has the title, the hint and the address row besides.
    private static let maxServersBesideQR = 3

    var body: some View {
        ZStack {
            OnboardingBackground()
            if entersAddress {
                addressScreen
                    .transition(.opacity)
            } else {
                phoneScreen
                    .transition(.opacity)
            }
        }
        .animation(Theme.Motion.easeOut, value: entersAddress)
        .onAppear {
            if address.isEmpty, let server = appState.server {
                address = Self.editableAddress(for: server.url)
            }
            focus = entersAddress ? (address.isEmpty ? .address : .connect) : .enterAddress
            browser.start()
            if !entersAddress { startSetup() }
        }
        .onDisappear {
            browser.stop()
            setup.stop()
        }
        .task {
            try? await Task.sleep(for: Self.searchPatience)
            searchSettled = true
        }
        .onChange(of: browser.servers) { old, servers in
            // The first server found takes the focus from the first control, so a single
            // press of Select connects; a field with an address keeps it.
            guard old.isEmpty, let first = servers.first else { return }
            if entersAddress {
                guard trimmedAddress.isEmpty, focus == .address || focus == nil else { return }
            } else {
                guard focus == .enterAddress || focus == nil else { return }
            }
            focus = .server(first.id)
        }
        .onChange(of: entersAddress) { _, entering in
            errorMessage = nil
            if entering {
                setup.stop()
                focus = address.isEmpty ? .address : .connect
            } else {
                startSetup()
                focus = .enterAddress
            }
        }
        // Menu: from the address field back to the QR code; from the QR code back to
        // where the server screen was opened from, when it can go back.
        .onExitCommand(perform: entersAddress ? { entersAddress = false } : (canCancel ? cancel : nil))
    }

    private func startSetup() {
        let appState = appState
        setup.start { server, serverId in
            try await appState.setUpFromPhone(server: server, serverId: serverId)
        }
    }

    // MARK: Set up with the phone

    private var phoneScreen: some View {
        HStack(alignment: .center, spacing: 120) {
            VStack(alignment: .leading, spacing: 32) {
                BrandMark()
                VStack(alignment: .leading, spacing: 20) {
                    Text("Set up with your phone")
                        .font(Theme.Typography.pageTitle)
                        .foregroundStyle(Theme.Colors.label)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(setup.status == .unavailable
                         ? "Apple TV isn't connected to a home network, so the phone can't reach it. Choose a server below or enter its address with the remote."
                         : "Scan the code with your phone's camera or in the Antresol app.")
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.Colors.label2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                VStack(alignment: .leading, spacing: 14) {
                    discovered(limit: Self.maxServersBesideQR)
                    Button {
                        entersAddress = true
                    } label: {
                        FallbackRowLabel(title: "Enter Address with the Remote", systemImage: "keyboard")
                    }
                    .buttonStyle(SettingsRowButtonStyle())
                    .focused($focus, equals: .enterAddress)
                    .disabled(isConnecting)
                }
                .focusSection()
                if let errorMessage {
                    ErrorLine(message: errorMessage)
                }
                if canCancel {
                    Button("Cancel", action: cancel)
                        .buttonStyle(PillButtonStyle(kind: .glass))
                }
            }
            .frame(width: 900, alignment: .leading)

            if setup.status != .unavailable {
                setupCode
            }
        }
        .padding(.horizontal, Theme.Layout.margin)
    }

    /// The QR code of the setup URL (not focusable), or a spinner while it opens.
    @ViewBuilder
    private var setupCode: some View {
        if case .ready(let url) = setup.status {
            QRCodeView(text: url, size: PairingView.qrSize)
                .transition(.opacity)
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: Theme.Radius.sheet, style: .continuous)
                    .fill(Theme.Colors.fillSecondary)
                ProgressView()
            }
            .frame(width: PairingView.qrSize, height: PairingView.qrSize)
        }
    }

    // MARK: Address with the remote

    private var addressScreen: some View {
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
                discovered(limit: Self.maxServers)
                manualEntry
            }
            .frame(width: 760, alignment: .leading)
            .focusSection()
        }
        .padding(.horizontal, Theme.Layout.margin)
    }

    // MARK: Found on the network

    @ViewBuilder
    private func discovered(limit: Int) -> some View {
        let servers = Array(browser.servers.prefix(limit))
        SettingsSection("Servers on This Network") {
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
                    Text("Antresol can't look for servers: local network access is off. Turn it on in Settings > General > Privacy & Security > Local Network, or enter the address below.")
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

                Button("Cancel") { entersAddress = false }
                    .buttonStyle(PillButtonStyle(kind: .glass))
            }
        }
    }

    private var canCancel: Bool {
        appState.canCancelServerChange
    }

    private func cancel() {
        appState.cancelServerChange()
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
            } catch {
                errorMessage = Self.describe(error)
                focus = serverId.map(Field.server) ?? (entersAddress ? .address : .enterAddress)
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

/// A fallback on the QR screen as a settings row: a symbol, the title and a chevron.
private struct FallbackRowLabel: View {
    let title: LocalizedStringKey
    let systemImage: String

    var body: some View {
        HStack(spacing: 28) {
            Image(systemName: systemImage)
                .font(.system(size: 30, weight: .semibold))
                .frame(width: 44)
                .accessibilityHidden(true)
            Text(title)
                .lineLimit(1)
            Spacer(minLength: 24)
            Image(systemName: "chevron.right")
                .font(.system(size: 26, weight: .semibold))
                .opacity(0.5)
                .accessibilityHidden(true)
        }
        .padding(.vertical, 14)
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
