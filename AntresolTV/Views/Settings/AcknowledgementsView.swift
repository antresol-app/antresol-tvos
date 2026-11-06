import SwiftUI

/// Licences and credits.
struct AcknowledgementsView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 44) {
                Text("Acknowledgements")
                    .font(Theme.Typography.pageTitle)
                    .foregroundStyle(Theme.Colors.label)
                    .accessibilityAddTraits(.isHeader)
                entry(
                    "Antresol for Apple TV",
                    "The Apple TV app for the Antresol home media server. It is built only on Apple's system frameworks (SwiftUI, AVKit, MediaPlayer, TVServices) and contains no third-party code."
                )
                entry(
                    "Your library",
                    "Films, shows, music, artwork and descriptions all come from your own Antresol server. Nothing is sent anywhere else."
                )
                entry(
                    "Apple",
                    "The system font and SF Symbols are provided by Apple and used under Apple's licence terms."
                )
            }
            .frame(width: 1100, alignment: .leading)
            .padding(.vertical, 90)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.Colors.background.ignoresSafeArea())
    }

    private func entry(_ title: LocalizedStringKey, _ text: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(Theme.Typography.headline)
                .foregroundStyle(Theme.Colors.label)
            Text(text)
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Colors.label2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // Focusable so the page can scroll and the Menu button goes back.
        .focusable()
        .accessibilityElement(children: .combine)
    }
}
