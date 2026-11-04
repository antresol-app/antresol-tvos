import SwiftUI

/// Black page with a soft brand-coloured glow, behind the onboarding screens.
struct OnboardingBackground: View {
    var body: some View {
        ZStack {
            Theme.Colors.background
            RadialGradient(
                colors: [Color(hex: 0x9B2FC9).opacity(0.35), Color(hex: 0x3A1C8C).opacity(0.18), .clear],
                center: UnitPoint(x: 0.5, y: -0.1),
                startRadius: 0,
                endRadius: 1100
            )
        }
        .ignoresSafeArea()
    }
}

/// The Antresol logo mark and wordmark.
struct BrandMark: View {
    var size: CGFloat = 72

    var body: some View {
        HStack(spacing: size * 0.3) {
            Image("LogoMark")
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
            Text(verbatim: "Antresol")
                .font(.system(size: size * 0.6, weight: .bold))
                .foregroundStyle(Theme.Colors.label)
        }
        .accessibilityElement(children: .combine)
    }
}

/// A one-line error message in the system red.
struct ErrorLine: View {
    let message: String

    var body: some View {
        Label {
            Text(verbatim: message)
        } icon: {
            Image(systemName: "exclamationmark.circle.fill")
        }
        .font(Theme.Typography.meta)
        .foregroundStyle(Theme.Colors.red)
        .lineLimit(3)
    }
}
