import AntresolKit
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
/// - Disk: the server's bytes in `Caches/Artwork` (a copy at the width asked for, see
///   `ServerURLs.image(_:width:)`), reused for 7 days (the server's `max-age`); a file that
///   turns out not to decode at any size is removed. Launch removes the files not written
///   for 30 days, then the oldest over `byteCap`.
/// - Its own `URLSession` (four connections to a host, no `URLCache`: this cache is the
///   cache), so a cold grid does not queue the API calls behind its pictures.
/// - Concurrent requests for the same image share one download, whatever sizes they ask
///   for, and one decode per size; a download nobody waits for any more is cancelled.
/// - A few decodes run at once (`decodeSlots`); the others wait their turn.
final class ImagePipeline: @unchecked Sendable {
    static let shared = ImagePipeline()

    /// How long a downloaded image is reused without asking the server again.
    private static let maxAge: TimeInterval = 7 * 24 * 60 * 60
    /// Files not touched for this long are removed on launch.
    private static let evictAfter: TimeInterval = 30 * 24 * 60 * 60
    /// The disk cache is trimmed to this many bytes on launch, oldest files first.
    private static let byteCap = 300 * 1024 * 1024

    private static let imageSession: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.httpMaximumConnectionsPerHost = 4
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }()

    private let memory = NSCache<NSString, UIImage>()
    private let session: URLSession
    private let directory: URL
    private let lock = NSLock()
    /// A load of an image's original bytes and how many callers wait for it.
    private struct Download {
        let id: Int
        let task: Task<Data?, Never>
        var waiters: Int
    }

    /// By URL.
    private var downloads: [String: Download] = [:]
    private var nextDownloadID = 0
    /// By URL and size.
    private var decoding: [String: Task<UIImage?, Never>] = [:]
    /// Decodes at once: at most four, and one thread of the shared pool (as wide as the
    /// processor has cores) is left for the rest of the app while a grid scrolls.
    private let decodeSlots = ConcurrencyLimiter(limit: min(4, ProcessInfo.processInfo.activeProcessorCount - 1))

    init(session: URLSession? = nil) {
        self.session = session ?? Self.imageSession
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
    /// Returns nil when the image is missing, cannot be decoded or the request fails, and
    /// when the caller's task is cancelled.
    func image(for url: URL, headers: [String: String], maxPixelSize: CGFloat) async -> UIImage? {
        let key = Self.memoryKey(url, maxPixelSize)
        if let image = memory.object(forKey: key) {
            return image
        }
        guard let data = await originalData(for: url, headers: headers), !Task.isCancelled else { return nil }
        if let image = await decoded(data, key: key, maxPixelSize: maxPixelSize) {
            return image
        }
        // ImageIO knew the header but could not decode the picture (damaged, or half
        // written by the server): the copy on disk would be handed out for a week
        // without the server being asked again. Without it the next request asks.
        // Only when the file is the reason: one that still decodes small failed for
        // want of memory for this size (the hero asks for one picture at 96 and 1920),
        // and removing it would download it again on every appearance.
        if !Task.isCancelled, ArtworkDecoding.isUndecodable(data) {
            try? FileManager.default.removeItem(at: fileURL(for: url))
        }
        return nil
    }

    // MARK: - Loading

    /// The original bytes of `url`. Every size asked for at the same time shares one
    /// load (the hero wants its backdrop small for the tint and large for the screen).
    /// The load is cancelled when every caller waiting for it was (cells scrolled away).
    private func originalData(for url: URL, headers: [String: String]) async -> Data? {
        let key = url.absoluteString
        let (id, task): (Int, Task<Data?, Never>) = lock.withLock {
            if var running = downloads[key] {
                running.waiters += 1
                downloads[key] = running
                return (running.id, running.task)
            }
            nextDownloadID += 1
            let task = Task.detached(priority: .userInitiated) { [self] in
                await fetch(url: url, headers: headers)
            }
            downloads[key] = Download(id: nextDownloadID, task: task, waiters: 1)
            return (nextDownloadID, task)
        }
        return await withTaskCancellationHandler {
            let data = await task.value
            lock.withLock {
                if downloads[key]?.id == id { downloads[key] = nil }
            }
            return data
        } onCancel: {
            lock.withLock {
                guard var running = downloads[key], running.id == id else { return }
                running.waiters -= 1
                if running.waiters == 0 {
                    running.task.cancel()
                    downloads[key] = nil
                } else {
                    downloads[key] = running
                }
            }
        }
    }

    /// From the disk cache while fresh, else from the server (kept on disk when it is an
    /// image), else a stale copy.
    private func fetch(url: URL, headers: [String: String]) async -> Data? {
        let file = fileURL(for: url)
        if let data = freshData(at: file), ArtworkDecoding.isImage(data) {
            return data
        }
        var request = URLRequest(url: url)
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200, ArtworkDecoding.isImage(data) else {
                return nil
            }
            try? data.write(to: file, options: .atomic)
            return data
        } catch {
            guard !Task.isCancelled else { return nil }
            // Offline: fall back to a stale copy if there is one.
            return try? Data(contentsOf: file, options: .mappedIfSafe)
        }
    }

    /// Decodes `data` for one size and keeps it in memory; callers wanting the same size at
    /// the same time share the work.
    private func decoded(_ data: Data, key: NSString, maxPixelSize: CGFloat) async -> UIImage? {
        let task: Task<UIImage?, Never> = lock.withLock {
            if let running = decoding[key as String] {
                return running
            }
            let task = Task.detached(priority: .userInitiated) { [memory, decodeSlots] () -> UIImage? in
                if let image = memory.object(forKey: key) { return image }
                guard let image = await decodeSlots.run({ Self.decode(data, maxPixelSize: maxPixelSize) }) else { return nil }
                memory.setObject(image, forKey: key, cost: Self.cost(of: image))
                return image
            }
            decoding[key as String] = task
            return task
        }
        let image = await task.value
        // Only this decode's entry: a waiter that comes back late must not remove a
        // newer decode of the same picture (others would start it once more).
        lock.withLock {
            if decoding[key as String] == task { decoding[key as String] = nil }
        }
        return image
    }

    private func freshData(at file: URL) -> Data? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
              let modified = attributes[.modificationDate] as? Date,
              Date().timeIntervalSince(modified) < Self.maxAge
        else { return nil }
        return try? Data(contentsOf: file, options: .mappedIfSafe)
    }

    private func fileURL(for url: URL) -> URL {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(name)
    }

    /// Removes the files not written for `evictAfter`, then the oldest ones while the rest
    /// is over `byteCap`.
    private static func evictStaleFiles(in directory: URL) {
        let manager = FileManager.default
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        guard let urls = try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys) else { return }
        let now = Date()
        var kept: [(file: URL, modified: Date, size: Int)] = []
        for file in urls {
            let values = try? file.resourceValues(forKeys: Set(keys))
            let modified = values?.contentModificationDate ?? now
            if now.timeIntervalSince(modified) > evictAfter {
                try? manager.removeItem(at: file)
            } else {
                kept.append((file, modified, values?.fileSize ?? 0))
            }
        }
        var total = kept.reduce(0) { $0 + $1.size }
        for entry in kept.sorted(by: { $0.modified < $1.modified }) where total > byteCap {
            try? manager.removeItem(at: entry.file)
            total -= entry.size
        }
    }

    // MARK: - Decoding

    /// (`ArtworkDecoding`, in the kit, is the ImageIO part: it has the unit tests.)
    private static func decode(_ data: Data, maxPixelSize: CGFloat) -> UIImage? {
        ArtworkDecoding.thumbnail(data, maxPixelSize: Int(maxPixelSize)).map { UIImage(cgImage: $0) }
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
