import SwiftUI

/// The design's segmented pill: options in a dark glass capsule, the selected one drawn
/// as a white pill with black text. Selection changes when an option is clicked, not when
/// it gains focus, so moving focus through the control (for example up from a grid)
/// never reloads content by accident.
struct SegmentedPill<Value: Hashable>: View {
    struct Option: Identifiable {
        let value: Value
        let title: String
        var id: Value { value }
    }

    let options: [Option]
    @Binding var selection: Value

    var body: some View {
        HStack(spacing: 6) {
            ForEach(options) { option in
                Button {
                    selection = option.value
                } label: {
                    Text(verbatim: option.title)
                }
                .buttonStyle(SegmentButtonStyle(isSelected: option.value == selection))
                .accessibilityAddTraits(option.value == selection ? .isSelected : [])
            }
        }
        .padding(6)
        .background(Theme.Colors.glassFill, in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.Colors.glassBorder, lineWidth: 1.5))
        .focusSection()
    }
}

private struct SegmentButtonStyle: ButtonStyle {
    let isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        SegmentBody(configuration: configuration, isSelected: isSelected)
    }
}

private struct SegmentBody: View {
    let configuration: ButtonStyleConfiguration
    let isSelected: Bool
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        configuration.label
            .font(Theme.Typography.segment)
            .lineLimit(1)
            .foregroundStyle(isSelected || isFocused ? Theme.Colors.labelInverse : Theme.Colors.label2)
            .padding(.horizontal, 30)
            .frame(minHeight: 60)
            .background(background, in: Capsule())
            .scaleEffect(isFocused ? Theme.Motion.focusScale : (configuration.isPressed ? 0.97 : 1))
            .shadow(color: .black.opacity(isFocused ? 0.5 : 0), radius: 16, y: 8)
            .animation(Theme.Motion.easeOut, value: isFocused)
            .animation(Theme.Motion.easeOut, value: isSelected)
    }

    private var background: Color {
        if isSelected { return .white }
        // A focused, unselected option is a lighter pill so it reads differently from the
        // selected one while staying legible from the couch.
        return isFocused ? Color.white.opacity(0.78) : .clear
    }
}
