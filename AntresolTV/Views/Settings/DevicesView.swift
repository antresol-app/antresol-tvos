import AntresolKit
import SwiftUI

/// The profile's signed-in devices (`GET /api/me/devices`): this Apple TV first, then the
/// others by when they were last seen. Selecting another device asks, then signs it out.
struct DevicesView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.locale) private var locale
    @State private var loader = ContentLoader<[DeviceSession]>()
    @State private var pendingRevoke: DeviceSession?
    @State private var revokingId: Int?
    @State private var actionError: String?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                Text("Devices")
                    .font(Theme.Typography.pageTitle)
                    .foregroundStyle(Theme.Colors.label)
                    .padding(.leading, 8)
                    .accessibilityAddTraits(.isHeader)
                Text("Apps signed in to this profile. Signing a device out means it has to sign in again; the web app is not listed.")
                    .font(Theme.Typography.cardMeta)
                    .foregroundStyle(Theme.Colors.label3)
                    .padding(.leading, 8)
                    .padding(.bottom, 36)

                if let actionError {
                    ErrorLine(message: actionError)
                        .padding(.leading, 8)
                        .padding(.bottom, 12)
                }

                switch loader.state {
                case .loading:
                    ProgressView().frame(maxWidth: .infinity, minHeight: 300)
                case .failed(let message):
                    ErrorStateView(message: message) { Task { await load() } }
                        .frame(minHeight: 500)
                case .loaded(let devices):
                    ForEach(devices) { device in
                        row(for: device)
                    }
                }
            }
            .buttonStyle(SettingsRowButtonStyle())
            .frame(width: 1100)
            .padding(.vertical, 90)
            .frame(maxWidth: .infinity)
        }
        .scrollClipDisabled()
        .background(Theme.Colors.background.ignoresSafeArea())
        .task { await load() }
        .confirmationDialog(
            Text(verbatim: String(localized: "Sign out “\(pendingRevoke?.name ?? "")”?", bundle: .localized)),
            isPresented: Binding(get: { pendingRevoke != nil }, set: { if !$0 { pendingRevoke = nil } }),
            titleVisibility: .visible,
            presenting: pendingRevoke
        ) { device in
            Button("Sign Out Device", role: .destructive) {
                Task { await revoke(device) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("The device stops playing and has to sign in to this profile again.")
        }
    }

    @ViewBuilder
    private func row(for device: DeviceSession) -> some View {
        let label = DeviceRowLabel(device: device, detail: detail(for: device), isRevoking: revokingId == device.id)
        if device.current {
            // This Apple TV signs out from the Settings page; the row only identifies it.
            Button {} label: { label }
                .accessibilityHint(Text("This Apple TV"))
        } else {
            Button {
                pendingRevoke = device
            } label: {
                label
            }
            .disabled(revokingId != nil)
            .accessibilityHint(Text("Signs this device out"))
        }
    }

    /// "AppleTV14,1 · 1.0 · Last seen 5 minutes ago".
    private func detail(for device: DeviceSession) -> String {
        var lastSeen = ""
        if let date = device.lastSeenDate {
            let formatter = RelativeDateTimeFormatter()
            formatter.locale = locale
            formatter.unitsStyle = .full
            let relative = formatter.localizedString(for: min(date, .now), relativeTo: .now)
            lastSeen = String(localized: "Last seen \(relative)", bundle: .localized)
        }
        return metaLine([device.model, device.version, lastSeen])
    }

    private func load() async {
        await loader.load(using: appState) { DeviceSession.displayOrder(try await $0.devices()) }
    }

    private func revoke(_ device: DeviceSession) async {
        guard let client = appState.client else { return }
        revokingId = device.id
        actionError = nil
        defer { revokingId = nil }
        do {
            try await client.revokeDevice(id: device.id)
            loader.update { $0.removeAll { $0.id == device.id } }
        } catch {
            actionError = appState.message(for: error)
        }
    }
}

private struct DeviceRowLabel: View {
    let device: DeviceSession
    let detail: String
    let isRevoking: Bool

    var body: some View {
        HStack(spacing: 24) {
            Image(systemName: Self.symbol(for: device.model))
                .font(.system(size: 34, weight: .regular))
                .frame(width: 56)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: device.name.isEmpty ? String(localized: "Unnamed device", bundle: .localized) : device.name)
                    .lineLimit(1)
                if !detail.isEmpty {
                    Text(verbatim: detail)
                        .font(Theme.Typography.cardMeta)
                        .opacity(0.65)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 40)
            if isRevoking {
                ProgressView()
            } else if device.current {
                Text("This Apple TV")
                    .font(Theme.Typography.meta)
                    .opacity(0.65)
            } else {
                Image(systemName: "rectangle.portrait.and.arrow.right")
                    .font(.system(size: 26, weight: .semibold))
                    .opacity(0.5)
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, 12)
    }

    /// A symbol for the registered model ("AppleTV14,1", "iPhone15,2", "Pixel 8").
    private static func symbol(for model: String) -> String {
        let model = model.lowercased()
        if model.hasPrefix("appletv") || model.contains("apple tv") { return "appletv" }
        if model.hasPrefix("iphone") { return "iphone" }
        if model.hasPrefix("ipad") { return "ipad" }
        if model.contains("mac") { return "laptopcomputer" }
        if model.contains("tv") { return "tv" }
        return "rectangle.on.rectangle"
    }
}
