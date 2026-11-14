import AntresolKit
import SwiftUI

/// "Sign in with your phone": the server's QR code and the code as text. A signed-in
/// phone approves (the Antresol app's scanner, or the phone camera opening the server's
/// `/pair` page) and this Apple TV is signed in to that profile with a normal device token.
/// The code is renewed when it expires; the profile picker stays one press away.
struct PairingView: View {
    @Environment(AppState.self) private var appState
    @State private var state: PairingState = .starting
    /// Bumped by "Get a New Code" after a denial: restarts the session.
    @State private var attempt = 0
    @State private var finishError: String?
    @FocusState private var focus: Action?

    private enum Action: Hashable {
        case newCode, remote, changeServer
    }

    var body: some View {
        ZStack {
            OnboardingBackground()
            HStack(alignment: .center, spacing: 120) {
                instructions
                    .frame(width: 900, alignment: .leading)
                codePanel
            }
            .padding(.horizontal, Theme.Layout.margin)
        }
        .task(id: attempt) { await run() }
        .onAppear { focus = .remote }
        .onChange(of: needsNewCode) { _, needed in
            if needed { focus = .newCode }
        }
        // Menu leaves for the server screen (its Cancel comes back here).
        .onExitCommand { appState.changeServer() }
    }

    // MARK: Text and actions

    private var instructions: some View {
        VStack(alignment: .leading, spacing: 36) {
            BrandMark()
            Text("Sign in with your phone")
                .font(Theme.Typography.pageTitle)
                .foregroundStyle(Theme.Colors.label)
                .fixedSize(horizontal: false, vertical: true)
            Text(hint)
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Colors.label2)
                .fixedSize(horizontal: false, vertical: true)

            statusLine
                .frame(minHeight: 44, alignment: .leading)

            HStack(spacing: 28) {
                if needsNewCode {
                    Button {
                        attempt += 1
                    } label: {
                        Label("Get a New Code", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(PillButtonStyle(kind: .primary))
                    .focused($focus, equals: .newCode)
                }
                Button {
                    appState.signInMethod = .remote
                } label: {
                    Label("Sign In with the Remote", systemImage: "person.2")
                }
                .buttonStyle(PillButtonStyle(kind: .glass))
                .focused($focus, equals: .remote)

                // Three pills do not fit the column: with "Get a New Code" up, Menu is the
                // way to the server screen.
                if !needsNewCode {
                    Button {
                        appState.changeServer()
                    } label: {
                        Label("Change Server", systemImage: "server.rack")
                    }
                    .buttonStyle(PillButtonStyle(kind: .glass))
                    .focused($focus, equals: .changeServer)
                }
            }
            .fixedSize()
            .focusSection()

            if let server = appState.server {
                Text("Antresol \(server.version) · \(server.displayName)")
                    .font(Theme.Typography.meta)
                    .foregroundStyle(Theme.Colors.label3)
            }
        }
    }

    /// The session ended without a sign-in (declined, or the token could not be kept).
    private var needsNewCode: Bool { state == .denied || finishError != nil }

    /// "Scan … or open <host>/pair and type the code".
    private var hint: String {
        let page = ticket?.pairPage ?? appState.server.map { ServerAddress.displayName($0.url) + "/pair" } ?? "/pair"
        return String(localized: "Scan the code with your phone's camera or the Antresol app. Or open \(page) on a phone signed in to Antresol and type the code.", bundle: .localized)
    }

    @ViewBuilder
    private var statusLine: some View {
        if let finishError {
            ErrorLine(message: finishError)
        } else {
            switch state {
            case .approved:
                HStack(spacing: 20) {
                    ProgressView()
                    Text("Approved on the phone. Signing in…")
                        .font(Theme.Typography.meta)
                        .foregroundStyle(Theme.Colors.label2)
                }
            case .denied:
                ErrorLine(message: String(localized: "Sign-in was declined on the phone.", bundle: .localized))
            case .failed(let message, _):
                ErrorLine(message: message)
            default:
                EmptyView()
            }
        }
    }

    // MARK: The code

    private var ticket: PairingTicket? {
        if case .waiting(let ticket) = state { return ticket }
        return nil
    }

    private var codePanel: some View {
        VStack(spacing: 40) {
            if let ticket {
                QRCodeView(text: ticket.url, size: Self.qrSize)
                    .transition(.opacity)
                VStack(spacing: 12) {
                    Text(verbatim: ticket.displayCode)
                        .font(Theme.Typography.pairingCode)
                        .tracking(6)
                        .foregroundStyle(Theme.Colors.label)
                        .accessibilityLabel(Text(verbatim: ticket.code.map(String.init).joined(separator: " ")))
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text("Code expires in \(Self.countdown(until: ticket.expiresAt, now: context.date))")
                            .font(Theme.Typography.meta)
                            .monospacedDigit()
                            .foregroundStyle(Theme.Colors.label3)
                    }
                }
            } else {
                placeholder
            }
        }
        .frame(width: Self.qrSize)
        .animation(Theme.Motion.easeOut, value: ticket?.code)
    }

    /// The QR's place while there is no code: a spinner, or the state's symbol.
    private var placeholder: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Theme.Radius.sheet, style: .continuous)
                .fill(Theme.Colors.fillSecondary)
            if needsNewCode {
                Image(systemName: "xmark.circle")
                    .font(.system(size: 120, weight: .light))
                    .foregroundStyle(Theme.Colors.label3)
            } else if case .approved = state {
                Image(systemName: "checkmark.circle")
                    .font(.system(size: 120, weight: .light))
                    .foregroundStyle(Theme.Colors.label2)
            } else {
                ProgressView()
            }
        }
        .frame(width: Self.qrSize, height: Self.qrSize)
    }

    static let qrSize: CGFloat = 520

    /// "4:32".
    static func countdown(until end: Date, now: Date) -> String {
        let seconds = max(0, Int(end.timeIntervalSince(now).rounded(.up)))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    // MARK: Session

    private func run() async {
        guard let session = appState.makePairingSession() else { return }
        finishError = nil
        do {
            let result = try await session.run { new in
                await MainActor.run { state = new }
            }
            switch result {
            case .approved(let token, let user):
                do {
                    try appState.signIn(pairedToken: token, user: user)
                } catch {
                    finishError = AppState.userMessage(for: error)
                }
            case .unsupported:
                appState.pairingUnsupported()
            default:
                break
            }
        } catch {
            // cancelled: the screen went away
        }
    }
}

#Preview {
    PairingView()
        .environment(AppState())
}
