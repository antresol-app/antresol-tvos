import SwiftUI

/// One choice on a `SettingsChoiceView`.
struct SettingsOption<Value: Hashable>: Identifiable {
    let value: Value
    let title: String

    var id: Value { value }
}

/// A pushed page listing the choices for one setting; the current one has a check mark
/// and starts focused. Picking one saves it and goes back.
struct SettingsChoiceView<Value: Hashable>: View {
    let title: LocalizedStringKey
    var footnote: LocalizedStringKey?
    let options: [SettingsOption<Value>]
    @Binding var selection: Value

    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Value?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(title)
                    .font(Theme.Typography.pageTitle)
                    .foregroundStyle(Theme.Colors.label)
                    .padding(.leading, 8)
                    .padding(.bottom, 36)
                    .accessibilityAddTraits(.isHeader)
                ForEach(options) { option in
                    Button {
                        selection = option.value
                        dismiss()
                    } label: {
                        SettingsRowLabel(
                            verbatim: option.title,
                            symbol: option.value == selection ? "checkmark" : nil
                        )
                    }
                    .focused($focused, equals: option.value)
                    .accessibilityAddTraits(option.value == selection ? .isSelected : [])
                }
                if let footnote {
                    Text(footnote)
                        .font(Theme.Typography.cardMeta)
                        .foregroundStyle(Theme.Colors.label3)
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
        .defaultFocus($focused, selection)
    }
}
