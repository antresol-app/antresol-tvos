#if canImport(ImageIO)
import Foundation
import ImageIO

/// Decoding of downloaded artwork with ImageIO (Apple platforms only), and the rule for
/// a file that did not decode.
public enum ArtworkDecoding {
    /// The size of the smallest decode: whether a file can be decoded at all.
    public static let probePixelSize = 16

    /// Whether ImageIO recognises `data` as an image (the header only, nothing is decoded).
    public static func isImage(_ data: Data) -> Bool {
        let options: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithData(data as CFData, options as CFDictionary) else { return false }
        return CGImageSourceGetCount(source) > 0
    }

    /// `data` decoded and scaled down so its longest side is at most `maxPixelSize`.
    public static func thumbnail(_ data: Data, maxPixelSize: Int) -> CGImage? {
        let sourceOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions as CFDictionary) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, maxPixelSize),
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// After a decode of `data` at the size asked for failed: whether the file itself is
    /// the reason (it does not decode at the smallest size either), so its cached copy
    /// should go. A file that still decodes small failed for another reason (no memory
    /// for the large picture), and is kept.
    public static func isUndecodable(_ data: Data) -> Bool {
        thumbnail(data, maxPixelSize: probePixelSize) == nil
    }
}
#endif
