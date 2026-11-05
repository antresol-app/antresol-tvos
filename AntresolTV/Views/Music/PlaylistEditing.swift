import AntresolKit
import SwiftUI

/// App-wide playlist actions, owned by the shell: the Add to Playlist picker, a short
/// confirmation message, and a revision that tells playlist lists to reload after any
/// playlist changed.
@MainActor
@Observable
final class PlaylistActions {
    /// Songs waiting for the picker to choose their playlist.
    struct AddRequest: Identifiable {
        let id = UUID()
        let trackIds: [Int]
    }

    var addRequest: AddRequest?
    private(set) var revision = 0
    private(set) var message: String?
    @ObservationIgnored private var messageTask: Task<Void, Never>?

    /// Opens the picker for these songs.
    func add(_ tracks: [Track]) {
        guard !tracks.isEmpty else { return }
        addRequest = AddRequest(trackIds: tracks.map(\.id))
    }

    /// Records that a playlist changed, optionally confirming it with a message.
    func changed(_ message: String? = nil) {
        revision += 1
        guard let message else { return }
        messageTask?.cancel()
        self.message = message
        messageTask = Task {
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self.message = nil
        }
    }
}

/// Name entry for a new or renamed playlist: a text field (Select opens the keyboard),
/// the action and Cancel. Menu cancels.
struct PlaylistNameView: View {
    let title: LocalizedStringKey
    let actionTitle: LocalizedStringKey
    var initialName = ""
    /// Saves the trimmed name; a thrown error is shown under the field.
    let save: (String) async throws -> Void
    let onCancel: () -> Void

    @Environment(AppState.self) private var appState
    @State private var name = ""
    @State private var isSaving = false
    @State private var errorMessage: String?
    @FocusState private var isFieldFocused: Bool

    private var validName: String? { PlaylistEditing.normalizedName(name) }

    var body: some View {
        VStack(spacing: 44) {
            Image(systemName: "music.note.list")
                .font(.system(size: 120, weight: .regular))
                .foregroundStyle(Theme.Colors.label2)
                .accessibilityHidden(true)
            Text(title)
                .font(Theme.Typography.pageTitle)
                .foregroundStyle(Theme.Colors.label)
                .accessibilityAddTraits(.isHeader)
            TextField("Playlist Name", text: $name)
                .focused($isFieldFocused)
                .submitLabel(.done)
                .onSubmit(submit)
                .disabled(isSaving)
                .frame(width: 760)

            Group {
                if isSaving {
                    ProgressView()
                } else if let errorMessage {
                    ErrorLine(message: errorMessage)
                }
            }
            .frame(minHeight: 44)

            HStack(spacing: 28) {
                Button(action: submit) {
                    Text(actionTitle)
                }
                .buttonStyle(PillButtonStyle(kind: .primary))
                .disabled(validName == nil || isSaving)

                Button("Cancel", action: onCancel)
                    .buttonStyle(PillButtonStyle(kind: .glass))
            }
            .focusSection()
        }
        .padding(.horizontal, Theme.Layout.margin)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.Colors.background.ignoresSafeArea())
        .onAppear {
            name = initialName
            isFieldFocused = true
        }
        .onExitCommand(perform: onCancel)
    }

    private func submit() {
        guard let validName, !isSaving else { return }
        isSaving = true
        errorMessage = nil
        Task {
            do {
                try await save(validName)
            } catch {
                errorMessage = appState.message(for: error)
            }
            isSaving = false
        }
    }
}

/// The Add to Playlist picker: New Playlist… and the profile's playlists. Choosing one
/// appends the songs and closes the picker.
struct AddToPlaylistView: View {
    let request: PlaylistActions.AddRequest

    @Environment(AppState.self) private var appState
    @Environment(PlaylistActions.self) private var actions
    @Environment(\.dismiss) private var dismiss
    @State private var loader = ContentLoader<[Playlist]>()
    @State private var isNaming = false
    @State private var isAdding = false
    @State private var errorMessage: String?

    var body: some View {
        if isNaming {
            PlaylistNameView(title: "New Playlist", actionTitle: "Create") { name in
                guard let client = appState.client else { return }
                let playlist = try await client.createPlaylist(name: name, trackIds: request.trackIds)
                finish(addedTo: playlist)
            } onCancel: {
                isNaming = false
            }
        } else {
            picker
        }
    }

    private var picker: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Add to Playlist")
                    .font(Theme.Typography.pageTitle)
                    .foregroundStyle(Theme.Colors.label)
                    .padding(.leading, 8)
                    .accessibilityAddTraits(.isHeader)
                Text(verbatim: String(localized: "\(request.trackIds.count) songs", bundle: .localized))
                    .font(Theme.Typography.meta)
                    .foregroundStyle(Theme.Colors.label2)
                    .padding(.leading, 8)
                    .padding(.bottom, 36)

                Button {
                    isNaming = true
                } label: {
                    SettingsRowLabel("New Playlist…", symbol: "plus")
                }
                .disabled(isAdding)

                switch loader.state {
                case .loading:
                    ProgressView().frame(maxWidth: .infinity, minHeight: 200)
                case .failed(let message):
                    ErrorLine(message: message)
                        .padding(.leading, 8)
                case .loaded(let playlists):
                    ForEach(playlists) { playlist in
                        Button {
                            Task { await add(to: playlist) }
                        } label: {
                            SettingsRowLabel(
                                verbatim: playlist.name,
                                value: String(localized: "\(playlist.trackCount) songs", bundle: .localized)
                            )
                        }
                        .disabled(isAdding)
                    }
                }

                if let errorMessage {
                    ErrorLine(message: errorMessage)
                        .padding(.leading, 8)
                        .padding(.top, 12)
                }
            }
            .buttonStyle(SettingsRowButtonStyle())
            .frame(width: 960)
            .padding(.vertical, 90)
            .frame(maxWidth: .infinity)
        }
        .scrollClipDisabled()
        .background(Theme.Colors.background.ignoresSafeArea())
        .task { await loader.load(using: appState) { try await $0.playlists() } }
    }

    private func add(to playlist: Playlist) async {
        guard let client = appState.client, !isAdding else { return }
        isAdding = true
        errorMessage = nil
        defer { isAdding = false }
        do {
            let updated = try await client.updatePlaylist(id: playlist.id, .append(request.trackIds))
            finish(addedTo: updated)
        } catch {
            errorMessage = appState.message(for: error)
        }
    }

    private func finish(addedTo playlist: Playlist) {
        actions.changed(String(localized: "Added to “\(playlist.name)”", bundle: .localized))
        dismiss()
    }
}

extension View {
    /// Asks before deleting `playlist` (bound while the question is up), then deletes it.
    func confirmsPlaylistDeletion(_ playlist: Binding<Playlist?>, delete: @escaping (Playlist) -> Void) -> some View {
        confirmationDialog(
            Text(verbatim: String(localized: "Delete “\(playlist.wrappedValue?.name ?? "")”?", bundle: .localized)),
            isPresented: Binding(get: { playlist.wrappedValue != nil }, set: { if !$0 { playlist.wrappedValue = nil } }),
            titleVisibility: .visible,
            presenting: playlist.wrappedValue
        ) { target in
            Button("Delete Playlist", role: .destructive) { delete(target) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("The playlist is removed from every device. The songs stay in the library.")
        }
    }
}
