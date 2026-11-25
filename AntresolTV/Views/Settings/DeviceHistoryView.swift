import AntresolKit
import SwiftUI

/// «Отдельная история на этом устройстве», as the web's «Устройства» has it for one device:
/// the person stays signed in, this Apple TV writes its progress, watched marks, Continue
/// Watching and the family view into one of the person's separate histories. Off goes back
/// to the profile's own history after the web's question: move what was watched here into
/// the profile, or keep it apart (it comes back when switched on again). A switch starts
/// the shell again for the new history (`RootView`), so this page goes with it. Not shown
/// to a kid: the server refuses a kid's switch, it is an administrator's.
struct DeviceHistoryView: View {
    let current: HistoryRef?

    @Environment(AppState.self) private var appState
    @State private var accounts: [ManagedAccount]?
    @State private var isWorking = false
    @State private var errorMessage: String?
    @State private var isAskingOff = false
    @FocusState private var focused: Row?

    private enum Row: Hashable {
        case off
        case account(Int)
        case new
    }

    private var selectedRow: Row { current.map { .account($0.id) } ?? .off }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Separate History on This Device")
                    .font(Theme.Typography.pageTitle)
                    .foregroundStyle(Theme.Colors.label)
                    .padding(.leading, 8)
                    .padding(.bottom, 36)
                    .accessibilityAddTraits(.isHeader)
                Button {
                    if current != nil { isAskingOff = true }
                } label: {
                    SettingsRowLabel("Off", symbol: current == nil ? "checkmark" : nil)
                }
                .focused($focused, equals: .off)
                .accessibilityAddTraits(current == nil ? .isSelected : [])

                Text("Separate Histories")
                    .font(Theme.Typography.eyebrow)
                    .tracking(2)
                    .textCase(.uppercase)
                    .foregroundStyle(Theme.Colors.label3)
                    .padding(.leading, 8)
                    .padding(.top, 30)
                    .accessibilityAddTraits(.isHeader)
                ForEach(accounts ?? []) { account in
                    Button {
                        guard account.id != current?.id else { return }
                        run { try await appState.setDeviceHistory(.on(accountId: account.id)) }
                    } label: {
                        SettingsRowLabel(verbatim: account.name, symbol: account.id == current?.id ? "checkmark" : nil)
                    }
                    .focused($focused, equals: .account(account.id))
                    .accessibilityAddTraits(account.id == current?.id ? .isSelected : [])
                }
                if accounts == nil {
                    ProgressView()
                        .padding(.leading, 8)
                }
                NavigationLink {
                    PlaylistNameView(
                        title: "Name",
                        actionTitle: "Create",
                        placeholder: "For example, Living Room",
                        symbol: "clock.arrow.circlepath",
                        save: { name in try await appState.createDeviceHistory(named: name) },
                        onCancel: nil
                    )
                } label: {
                    SettingsRowLabel("New History…")
                }
                .focused($focused, equals: .new)

                Group {
                    if isWorking {
                        ProgressView()
                    } else if let errorMessage {
                        ErrorLine(message: errorMessage)
                    }
                }
                .padding(.leading, 8)
                .frame(minHeight: 44)

                Text("Its Continue Watching, watched marks and Family Is Watching stay apart from yours.")
                    .font(Theme.Typography.cardMeta)
                    .foregroundStyle(Theme.Colors.label3)
                    .padding(.leading, 8)
            }
            .buttonStyle(SettingsRowButtonStyle())
            .disabled(isWorking)
            .frame(width: 960)
            .padding(.vertical, 90)
            .frame(maxWidth: .infinity)
        }
        .scrollClipDisabled()
        .background(Theme.Colors.background.ignoresSafeArea())
        .defaultFocus($focused, selectedRow)
        .task { await load() }
        .confirmationDialog(
            Text("Return “\(current?.name ?? "")” to your history?"),
            isPresented: $isAskingOff,
            titleVisibility: .visible
        ) {
            Button("Move to My Profile") { run { try await appState.setDeviceHistory(.off(merge: true)) } }
            Button("Keep Apart") { run { try await appState.setDeviceHistory(.off(merge: false)) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("What was watched on this device can move into your profile, or stay apart — it comes back if you turn this on again.")
        }
    }

    private func load() async {
        do {
            accounts = try await appState.managedAccounts()
        } catch {
            // The picker still offers Off and a new history.
            accounts = accounts ?? []
            errorMessage = appState.message(for: error)
        }
    }

    private func run(_ action: @escaping () async throws -> Void) {
        guard !isWorking else { return }
        isWorking = true
        errorMessage = nil
        Task {
            do {
                try await action()
            } catch {
                errorMessage = Self.failure(error, appState: appState)
            }
            isWorking = false
        }
    }

    /// The server's sentence (a refused switch, too many histories), else the web's
    /// «Не удалось переключить историю». A 401 signs out through `AppState`.
    static func failure(_ error: Error, appState: AppState) -> String? {
        if let error = error as? APIError, error.statusCode != 401, let message = error.serverMessage, !message.isEmpty {
            return message
        }
        guard appState.message(for: error) != nil else { return nil }
        return String(localized: "Couldn’t switch the history", bundle: .localized)
    }
}
