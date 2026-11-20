import AntresolKit
import CoreMedia
import VideoToolbox

/// What this Apple TV plays, as the server is told with every play request.
enum PlayerDevice {
    /// HEVC and AV1 only where there is a hardware decoder (Apple TV HD has neither and tops
    /// out at 1080p).
    static let caps: DeviceCaps = {
        let hevc = VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC)
        let av1 = VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1)
        return .appleTV(maxHeight: hevc ? 2160 : 1080, hevc: hevc, av1: av1)
    }()

    /// The tallest picture it shows: what an addon is told to stay within.
    static var maxHeight: Int { caps.maxHeight ?? 1080 }
}
