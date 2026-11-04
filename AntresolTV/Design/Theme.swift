import AntresolKit
import SwiftUI

/// Design tokens from docs/design-ref/DESIGN.md.
enum Theme {
    enum Colors {
        static let background = Color.black
        static let raised = Color(hex: 0x121214)
        static let elevated = Color(hex: 0x1C1C1E)
        static let label = Color(hex: 0xF5F5F7)
        static let label2 = Color(hex: 0xEBEBF5).opacity(0.7)
        static let label3 = Color(hex: 0xEBEBF5).opacity(0.45)
        static let accent = Color(hex: 0x0A84FF)
        static let green = Color(hex: 0x30D158)
        static let orange = Color(hex: 0xFF9F0A)
        static let red = Color(hex: 0xFF453A)
        static let hairline = Color.white.opacity(0.12)
        static let glassFill = Color(hex: 0x1C1C20).opacity(0.92)
        static let glassBorder = Color.white.opacity(0.08)
    }

    enum Gradients {
        /// Brand tile gradient, #3a1c8c → #9b2fc9 at 160°.
        static let brand = LinearGradient(
            colors: [Color(hex: 0x3A1C8C), Color(hex: 0x9B2FC9)],
            startPoint: UnitPoint(x: 0.33, y: 0.03),
            endPoint: UnitPoint(x: 0.67, y: 0.97)
        )

        /// Profile avatar gradient (145°).
        static func avatar(_ preset: AvatarPreset) -> LinearGradient {
            LinearGradient(
                colors: [Color(hex: preset.colors.from), Color(hex: preset.colors.to)],
                startPoint: UnitPoint(x: 0.21, y: 0.09),
                endPoint: UnitPoint(x: 0.79, y: 0.91)
            )
        }
    }

    enum Radius {
        static let card: CGFloat = 12
        static let smallCard: CGFloat = 10
        static let control: CGFloat = 12
        static let sheet: CGFloat = 20
        static let badge: CGFloat = 6
    }

    enum Motion {
        /// cubic-bezier(.22, 1, .36, 1)
        static let easeOut = Animation.timingCurve(0.22, 1, 0.36, 1, duration: 0.26)
        static let focusScale: CGFloat = 1.07
        static let cardLift: CGFloat = 1.04
    }
}

extension Color {
    /// A colour from a 24-bit RGB value such as 0x0A84FF.
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }
}
