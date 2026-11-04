import SwiftUI

/// Server-provided badges ("1080p", "Audio EN RU") as small outlined chips.
struct BadgeRow: View {
    let badges: [String]

    var body: some View {
        HStack(spacing: 8) {
            ForEach(badges, id: \.self) { badge in
                Text(verbatim: badge)
                    .font(Theme.Typography.badge)
                    .foregroundStyle(Theme.Colors.label2)
                    .lineLimit(1)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.Radius.badge, style: .continuous)
                            .fill(Theme.Colors.fillSecondary)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.Radius.badge, style: .continuous)
                            .strokeBorder(Theme.Colors.hairline, lineWidth: 1)
                    )
            }
        }
    }
}

/// A thin watched-fraction bar.
struct ProgressBar: View {
    /// 0...1.
    let value: Double
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.28))
                Capsule()
                    .fill(.white)
                    .frame(width: proxy.size.width * min(max(value, 0), 1))
            }
        }
        .frame(height: height)
        .accessibilityElement()
        .accessibilityValue(Text(verbatim: "\(Int((min(max(value, 0), 1) * 100).rounded()))%"))
    }
}
