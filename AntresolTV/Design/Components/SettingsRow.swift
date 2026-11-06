import SwiftUI

/// A settings row: a glass plate at rest that turns white with black text when focused,
/// like the design's pills, with the title on the left and the current value on the right.
struct SettingsRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        SettingsRowBody(configuration: configuration)
    }
}

private struct SettingsRowBody: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        configuration.label
            .font(Theme.Typography.headline)
            .foregroundStyle(isFocused ? Theme.Colors.labelInverse : Theme.Colors.label)
            .padding(.horizontal, 36)
            .frame(maxWidth: .infinity, minHeight: 92, alignment: .leading)
            .glassSurface(in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous), highlighted: isFocused)
            .scaleEffect(configuration.isPressed ? 0.99 : (isFocused ? 1.02 : 1))
            .shadow(color: .black.opacity(isFocused ? 0.45 : 0), radius: 18, y: 10)
            .animation(Theme.Motion.easeOut, value: isFocused)
    }
}

/// Title, value and an optional trailing symbol (chevron, check mark) of a settings row.
struct SettingsRowLabel: View {
    let title: Text
    var value: String?
    var symbol: String?

    init(_ title: LocalizedStringKey, value: String? = nil, symbol: String? = "chevron.right") {
        self.title = Text(title)
        self.value = value
        self.symbol = symbol
    }

    init(verbatim title: String, value: String? = nil, symbol: String? = nil) {
        self.title = Text(verbatim: title)
        self.value = value
        self.symbol = symbol
    }

    var body: some View {
        HStack(spacing: 24) {
            title
                .lineLimit(1)
            Spacer(minLength: 40)
            if let value {
                Text(verbatim: value)
                    .lineLimit(1)
                    .opacity(0.6)
            }
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 26, weight: .semibold))
                    .opacity(symbol == "chevron.right" ? 0.5 : 1)
                    .accessibilityHidden(symbol == "chevron.right")
            }
        }
    }
}

/// A read-only row (server address, version) on the same plate as the buttons.
struct SettingsInfoRow: View {
    let title: LocalizedStringKey
    let value: String

    var body: some View {
        HStack(spacing: 24) {
            Text(title)
                .foregroundStyle(Theme.Colors.label)
                .lineLimit(1)
            Spacer(minLength: 40)
            Text(verbatim: value)
                .foregroundStyle(Theme.Colors.label2)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .font(Theme.Typography.headline)
        .padding(.horizontal, 36)
        .frame(maxWidth: .infinity, minHeight: 92, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                .fill(Theme.Colors.fillSecondary)
        )
        .accessibilityElement(children: .combine)
    }
}
