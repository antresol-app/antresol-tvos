import Foundation

/// Profile avatar gradients `grad-1` ... `grad-8` (§2.3). Drawn at 145° behind the
/// first letter of the profile name. Unknown values map to `grad-8`.
public enum AvatarPreset: String, CaseIterable, Sendable {
    case grad1 = "grad-1"
    case grad2 = "grad-2"
    case grad3 = "grad-3"
    case grad4 = "grad-4"
    case grad5 = "grad-5"
    case grad6 = "grad-6"
    case grad7 = "grad-7"
    case grad8 = "grad-8"

    public static let fallback: AvatarPreset = .grad8

    public init(value: String) {
        self = AvatarPreset(rawValue: value) ?? .fallback
    }

    /// Gradient stops as 24-bit RGB values (from, to).
    public var colors: (from: UInt32, to: UInt32) {
        switch self {
        case .grad1: return (0x5E5CE6, 0xBF5AF2)
        case .grad2: return (0x0A84FF, 0x64D2FF)
        case .grad3: return (0xFF375F, 0xFF9F0A)
        case .grad4: return (0x30D158, 0x00C7BE)
        case .grad5: return (0xFF9F0A, 0xFFD60A)
        case .grad6: return (0xBF5AF2, 0xFF375F)
        case .grad7: return (0x00C7BE, 0x0A84FF)
        case .grad8: return (0x8E8E93, 0x48484A)
        }
    }

    /// Gradient angle in degrees, CSS convention (0° points up, clockwise).
    public static let angleDegrees: Double = 145
}
