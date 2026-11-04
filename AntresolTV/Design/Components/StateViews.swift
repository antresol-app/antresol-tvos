import SwiftUI

/// A full-page error with a retry button.
struct ErrorStateView: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 32) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 80))
                .foregroundStyle(Theme.Colors.label3)
            Text("Something went wrong")
                .font(Theme.Typography.sectionTitle)
                .foregroundStyle(Theme.Colors.label)
            Text(verbatim: message)
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Colors.label2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 1100)
            Button(action: retry) {
                Label("Try Again", systemImage: "arrow.clockwise")
            }
            .buttonStyle(PillButtonStyle(kind: .primary))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A full-page message for empty content.
struct EmptyStateView: View {
    let systemImage: String
    let title: LocalizedStringKey
    let message: LocalizedStringKey

    var body: some View {
        VStack(spacing: 28) {
            Image(systemName: systemImage)
                .font(.system(size: 80))
                .foregroundStyle(Theme.Colors.label3)
            Text(title)
                .font(Theme.Typography.sectionTitle)
                .foregroundStyle(Theme.Colors.label)
            Text(message)
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Colors.label2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 1100)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
