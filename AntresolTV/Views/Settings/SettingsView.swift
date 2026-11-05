import AntresolKit
import SwiftUI

/// The profile tab: who is signed in, playback and language preferences, the server, and
/// about. Choices open their own page, like the tvOS Settings app.
struct SettingsView: View {
    let user: User

    var body: some View {
        NavigationStack {
            SettingsPage(user: user)
        }
    }
}

private struct SettingsPage: View {
    let user: User

    @Environment(AppState.self) private var appState
    @Environment(\.locale) private var locale
    @AppStorage(PlayerPreferences.Key.quality) private var quality: VideoQuality = .auto
    @AppStorage(PlayerPreferences.Key.audioLanguage) private var audioLanguage: String?
    @AppStorage(PlayerPreferences.Key.subtitleLanguage) private var subtitleLanguage: String?
    @AppStorage(PlayerPreferences.Key.autoplayNext) private var autoplayNext = true
    @State private var isConfirmingSignOut = false
    @State private var showsServerEntry = false

    /// Languages offered for audio and subtitles (two-letter codes, as the player stores them).
    private static let mediaLanguages = ["en", "ru", "uk", "de", "fr", "es", "it", "pt", "pl", "ja", "ko", "zh"]

    var body: some View {
        HStack(alignment: .top, spacing: 110) {
            profileColumn
                .frame(width: 520)
                .padding(.top, 90)
                .focusSection()

            ScrollView {
                VStack(alignment: .leading, spacing: 60) {
                    playbackSection
                    languageSection
                    serverSection
                    aboutSection
                }
                .padding(.vertical, 80)
                .padding(.horizontal, 24)
            }
            // Clipped, so rows scrolled up end below the tab bar instead of under it; the
            // padding above leaves room for the focused row's lift.
            .focusSection()
        }
        .padding(.horizontal, Theme.Layout.margin)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Theme.Colors.background)
        .confirmationDialog("Sign out of this profile?", isPresented: $isConfirmingSignOut, titleVisibility: .visible) {
            Button("Sign Out", role: .destructive) {
                Task { await appState.signOut() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This Apple TV is removed from the profile's devices. You can sign in again from the profile picker.")
        }
        .fullScreenCover(isPresented: $showsServerEntry) {
            ServerEntryView { showsServerEntry = false }
                .environment(appState)
        }
    }

    // MARK: Profile

    private var profileColumn: some View {
        VStack(spacing: 28) {
            AvatarView(user: user, size: 260)
            Text(verbatim: user.name)
                .font(Theme.Typography.pageTitle)
                .foregroundStyle(Theme.Colors.label)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(role)
                .font(Theme.Typography.meta)
                .foregroundStyle(Theme.Colors.label2)
            VStack(spacing: 24) {
                Button {
                    appState.switchProfile()
                } label: {
                    Label("Switch Profile", systemImage: "person.2")
                        .frame(minWidth: 360)
                }
                Button {
                    isConfirmingSignOut = true
                } label: {
                    Label("Sign Out", systemImage: "rectangle.portrait.and.arrow.right")
                        .frame(minWidth: 360)
                }
            }
            .buttonStyle(PillButtonStyle(kind: .glass))
            .padding(.top, 24)
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

    // MARK: Playback

    private var playbackSection: some View {
        SettingsSection("Playback") {
            NavigationLink {
                SettingsChoiceView(
                    title: "Video Quality",
                    footnote: "Auto plays the original file when Apple TV can, and converts it otherwise.",
                    options: VideoQuality.allCases.map { SettingsOption(value: $0, title: $0.displayName) },
                    selection: $quality
                )
            } label: {
                SettingsRowLabel("Video Quality", value: quality.displayName)
            }

            NavigationLink {
                SettingsChoiceView(
                    title: "Audio Language",
                    footnote: "Used when a video has a track in this language. Automatic plays the file's default track.",
                    options: [SettingsOption(value: String?.none, title: String(localized: "Automatic", bundle: .localized))]
                        + Self.mediaLanguages.map { SettingsOption<String?>(value: $0, title: languageName($0)) },
                    selection: $audioLanguage
                )
            } label: {
                SettingsRowLabel("Audio Language", value: audioLanguage.map(languageName) ?? String(localized: "Automatic", bundle: .localized))
            }

            NavigationLink {
                SettingsChoiceView(
                    title: "Subtitles",
                    footnote: "Subtitles in this language turn on by themselves when a video has them.",
                    options: [SettingsOption(value: String?.none, title: String(localized: "Off", bundle: .localized))]
                        + Self.mediaLanguages.map { SettingsOption<String?>(value: $0, title: languageName($0)) },
                    selection: $subtitleLanguage
                )
            } label: {
                SettingsRowLabel("Subtitles", value: subtitleLanguage.map(languageName) ?? String(localized: "Off", bundle: .localized))
            }

            Button {
                autoplayNext.toggle()
            } label: {
                SettingsRowLabel(
                    "Autoplay Next Episode",
                    value: autoplayNext ? String(localized: "On", bundle: .localized) : String(localized: "Off", bundle: .localized),
                    symbol: nil
                )
            }
        }
    }

    // MARK: Language

    private var languageSection: some View {
        SettingsSection("Language", footnote: "Some text changes language the next time Antresol is opened.") {
            NavigationLink {
                SettingsChoiceView(
                    title: "App Language",
                    footnote: "Also the language the server uses for titles and descriptions.",
                    options: AppLanguage.allCases.map { SettingsOption(value: $0, title: languageTitle($0)) },
                    selection: Binding(get: { appState.language }, set: { appState.language = $0 })
                )
            } label: {
                SettingsRowLabel("App Language", value: languageTitle(appState.language))
            }
        }
    }

    private func languageTitle(_ language: AppLanguage) -> String {
        language.nativeName ?? String(localized: "System", bundle: .localized)
    }

    // MARK: Server

    @ViewBuilder
    private var serverSection: some View {
        if let server = appState.server {
            SettingsSection("Server") {
                SettingsInfoRow(title: "Address", value: server.displayName)
                SettingsInfoRow(title: "Version", value: server.version)
                NavigationLink {
                    DevicesView()
                } label: {
                    SettingsRowLabel("Devices")
                }
                // A kid profile cannot point the Apple TV at another server.
                if !user.isKid {
                    Button {
                        showsServerEntry = true
                    } label: {
                        SettingsRowLabel("Change Server", symbol: "server.rack")
                    }
                }
            }
        }
    }

    // MARK: About

    private var aboutSection: some View {
        SettingsSection("About This App") {
            SettingsInfoRow(title: "Antresol for Apple TV", value: Self.appVersion)
            NavigationLink {
                AcknowledgementsView()
            } label: {
                SettingsRowLabel("Acknowledgements")
            }
        }
    }

    private static var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "–"
        let build = info?["CFBundleVersion"] as? String ?? "–"
        return "\(version) (\(build))"
    }

    private func languageName(_ code: String) -> String {
        let name = locale.localizedString(forLanguageCode: code) ?? code
        return name.prefix(1).uppercased(with: locale) + name.dropFirst()
    }
}

/// A titled group of rows, with an optional note underneath.
private struct SettingsSection<Content: View>: View {
    let title: LocalizedStringKey
    let footnote: LocalizedStringKey?
    @ViewBuilder let content: () -> Content

    init(_ title: LocalizedStringKey, footnote: LocalizedStringKey? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.footnote = footnote
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title)
                .font(Theme.Typography.eyebrow)
                .tracking(2)
                .textCase(.uppercase)
                .foregroundStyle(Theme.Colors.label3)
                .padding(.leading, 8)
                .accessibilityAddTraits(.isHeader)
            VStack(spacing: 14) {
                content()
            }
            .buttonStyle(SettingsRowButtonStyle())
            if let footnote {
                Text(footnote)
                    .font(Theme.Typography.cardMeta)
                    .foregroundStyle(Theme.Colors.label3)
                    .padding(.leading, 8)
            }
        }
    }
}
