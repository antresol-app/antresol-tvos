import CoreImage
import CryptoKit
import Foundation
import ImageIO
import SwiftUI
import UIKit

/// Loads server artwork with the Bearer header (images reject `?mk=`), downsamples it with
/// ImageIO and caches it in memory and on disk.
///
/// - Memory: `NSCache` keyed by URL and target size, bounded by decoded byte cost.
/// - Disk: original bytes in `Caches/Artwork`, reused for 7 days (the server's `max-age`).
/// - Concurrent requests for the same image share one download.
final class ImagePipeline: @unchecked Sendable {
    static let shared = ImagePipeline()

    /// How long a downloaded image is reused without asking the server again.
    private static let maxAge: TimeInterval = 7 * 24 * 60 * 60
    /// Files not touched for this long are removed on launch.
    private static let evictAfter: TimeInterval = 30 * 24 * 60 * 60

    private let memory = NSCache<NSString, UIImage>()
    private let session: URLSession
    private let directory: URL
    private let lock = NSLock()
    private var inFlight: [String: Task<UIImage?, Never>] = [:]

    init(session: URLSession = .shared) {
        self.session = session
        memory.totalCostLimit = 192 * 1024 * 1024
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        directory = caches.appendingPathComponent("Artwork", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let directory = directory
        Task.detached(priority: .background) {
            Self.evictStaleFiles(in: directory)
        }
    }

    /// An already decoded image, without any I/O. Lets views render cached artwork in
    /// their first frame instead of flashing the placeholder.
    func cachedImage(for url: URL, maxPixelSize: CGFloat) -> UIImage? {
        memory.object(forKey: Self.memoryKey(url, maxPixelSize))
    }

    /// The image at `url`, scaled down so its longest side is at most `maxPixelSize`.
    /// Returns nil when the image is missing, cannot be decoded or the request fails.
    func image(for url: URL, headers: [String: String], maxPixelSize: CGFloat) async -> UIImage? {
        let key = Self.memoryKey(url, maxPixelSize)
        if let image = memory.object(forKey: key) {
            return image
        }
        let task: Task<UIImage?, Never> = lock.withLock {
            if let running = inFlight[key as String] {
                return running
            }
            let task = Task.detached(priority: .userInitiated) { [self] in
                await load(url: url, headers: headers, maxPixelSize: maxPixelSize)
            }
            inFlight[key as String] = task
            return task
        }
        let image = await task.value
        lock.withLock { inFlight[key as String] = nil }
        if let image {
            memory.setObject(image, forKey: key, cost: Self.cost(of: image))
        }
        return image
    }

    // MARK: - Loading

    private func load(url: URL, headers: [String: String], maxPixelSize: CGFloat) async -> UIImage? {
        let file = fileURL(for: url)
        if let data = freshData(at: file), let image = Self.decode(data, maxPixelSize: maxPixelSize) {
            return image
        }
        var request = URLRequest(url: url)
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let image = Self.decode(data, maxPixelSize: maxPixelSize)
            else {
                return nil
            }
            try? data.write(to: file, options: .atomic)
            return image
        } catch {
            // Offline or cancelled: fall back to a stale copy if there is one.
            return (try? Data(contentsOf: file)).flatMap { Self.decode($0, maxPixelSize: maxPixelSize) }
        }
    }

    private func freshData(at file: URL) -> Data? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
              let modified = attributes[.modificationDate] as? Date,
              Date().timeIntervalSince(modified) < Self.maxAge
        else { return nil }
        return try? Data(contentsOf: file)
    }

    private func fileURL(for url: URL) -> URL {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(name)
    }

    private static func evictStaleFiles(in directory: URL) {
        let manager = FileManager.default
        guard let files = try? manager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }
        let now = Date()
        for file in files {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let modified, now.timeIntervalSince(modified) > evictAfter {
                try? manager.removeItem(at: file)
            }
        }
    }

    // MARK: - Decoding

    private static func decode(_ data: Data, maxPixelSize: CGFloat) -> UIImage? {
        let sourceOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions as CFDictionary) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, Int(maxPixelSize)),
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: image)
    }

    private static func memoryKey(_ url: URL, _ maxPixelSize: CGFloat) -> NSString {
        "\(Int(maxPixelSize))|\(url.absoluteString)" as NSString
    }

    private static func cost(of image: UIImage) -> Int {
        guard let cgImage = image.cgImage else { return 1 }
        return cgImage.bytesPerRow * cgImage.height
    }

    // MARK: - Colour

    private static let colorContext = CIContext(options: [.workingColorSpace: NSNull()])

    /// The average colour of an image, normalised to a saturated mid-dark tone so it reads
    /// as a glow behind white text. Used to tint hero backgrounds.
    static func tintColor(of image: UIImage) -> Color? {
        guard let cgImage = image.cgImage else { return nil }
        let input = CIImage(cgImage: cgImage)
        guard let filter = CIFilter(name: "CIAreaAverage", parameters: [
            kCIInputImageKey: input,
            kCIInputExtentKey: CIVector(cgRect: input.extent),
        ]), let output = filter.outputImage else { return nil }
        var pixel = [UInt8](repeating: 0, count: 4)
        colorContext.render(
            output, toBitmap: &pixel, rowBytes: 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBA8, colorSpace: nil
        )
        let average = UIColor(
            red: CGFloat(pixel[0]) / 255,
            green: CGFloat(pixel[1]) / 255,
            blue: CGFloat(pixel[2]) / 255,
            alpha: 1
        )
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        guard average.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha) else { return nil }
        // Greyish artwork stays neutral instead of picking up a random hue.
        let tunedSaturation = saturation < 0.12 ? saturation : max(saturation, 0.6)
        return Color(hue: Double(hue), saturation: Double(tunedSaturation), brightness: Double(min(max(brightness, 0.38), 0.6)))
    }
}
