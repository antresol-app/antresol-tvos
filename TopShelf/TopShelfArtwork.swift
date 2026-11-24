import AntresolKit
import Foundation
import UIKit

/// Downloads Top Shelf artwork with the Bearer header (the server does not serve images
/// without it, so the system cannot fetch them itself) into the shared container, and
/// hands the system local file URLs.
struct TopShelfArtwork {
    let client: APIClient

    /// Files younger than this are reused without downloading again.
    private static let freshness: TimeInterval = 24 * 60 * 60
    /// Files not touched for this long are deleted.
    private static let expiry: TimeInterval = 7 * 24 * 60 * 60

    private var directory: URL {
        let base = SharedSessionStore.containerURL
            ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Library/Caches/TopShelf", isDirectory: true)
    }

    /// Pixels wide asked of the server for a tile: a 16:9 tile is 1216 wide on a 4K screen,
    /// a poster 808 (the server's steps, `ServerURLs.imageWidthStep`).
    static func width(for shape: TopShelfPlan.Shape) -> Int {
        switch shape {
        case .wide: return 1280
        case .poster: return 960
        }
    }

    /// Downloads at once: bytes go to disk, but a shelf of thirty-odd pictures asked for
    /// together would still queue as many connections on a small server.
    private static let concurrency = 4

    /// Local files for server image paths, each asked for at its width (pixels, as
    /// `width(for:)` has it); paths that fail to download are left out.
    func files(for widths: [String: Int]) async -> [String: URL] {
        let directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        return await withTaskGroup(of: (String, URL?).self) { group in
            var pending = widths.makeIterator()
            func start(_ next: (key: String, value: Int), in group: inout TaskGroup<(String, URL?)>) {
                group.addTask { (next.key, await file(for: next.key, width: next.value, in: directory)) }
            }
            for _ in 0..<Self.concurrency {
                guard let next = pending.next() else { break }
                start(next, in: &group)
            }
            var result: [String: URL] = [:]
            for await (path, file) in group {
                if let file { result[path] = file }
                if let next = pending.next() { start(next, in: &group) }
            }
            return result
        }
    }

    private func file(for path: String, width: Int, in directory: URL) async -> URL? {
        guard let url = client.urls.image(path, width: width) else { return nil }
        // The name carries the width: the same path may be a poster and a wide tile.
        let file = directory.appendingPathComponent(Self.fileName(for: url.absoluteString))
        if let modified = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
           Date().timeIntervalSince(modified) < Self.freshness {
            return file
        }
        var request = URLRequest(url: url, timeoutInterval: 15)
        for (field, value) in client.authorizationHeaders(for: url) {
            request.setValue(value, forHTTPHeaderField: field)
        }
        // Straight to disk: this extension has a small memory limit, and a picture held as
        // `Data` is as large as the file.
        func stale() -> URL? { FileManager.default.fileExists(atPath: file.path) ? file : nil }
        do {
            let (temporary, response) = try await URLSession.shared.download(for: request)
            defer { try? FileManager.default.removeItem(at: temporary) }
            let size = (try? temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            guard (response as? HTTPURLResponse)?.statusCode == 200, size > 0 else { return stale() }
            try? FileManager.default.removeItem(at: file)
            try FileManager.default.moveItem(at: temporary, to: file)
            return file
        } catch {
            // Offline: a stale copy is better than no artwork.
            return stale()
        }
    }

    /// The neutral picture of a programme without artwork: a dark system fill with the
    /// `tv` glyph (never a coloured tile), drawn once into the cache.
    func placeholderFile() -> URL? {
        let file = directory.appendingPathComponent("programme-placeholder-v1.png")
        if FileManager.default.fileExists(atPath: file.path) { return file }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let size = CGSize(width: 1096, height: 616)
        let image = UIGraphicsImageRenderer(size: size).image { context in
            UIColor(red: 0x1C / 255, green: 0x1C / 255, blue: 0x1E / 255, alpha: 1).setFill()
            context.fill(CGRect(origin: .zero, size: size))
            let config = UIImage.SymbolConfiguration(pointSize: 150, weight: .regular)
            if let glyph = UIImage(systemName: "tv", withConfiguration: config)?
                .withTintColor(UIColor(white: 0.92, alpha: 0.4), renderingMode: .alwaysOriginal) {
                let origin = CGPoint(x: (size.width - glyph.size.width) / 2, y: (size.height - glyph.size.height) / 2)
                glyph.draw(at: origin)
            }
        }
        guard let data = image.pngData(), (try? data.write(to: file, options: .atomic)) != nil else { return nil }
        return file
    }

    /// Deletes the files older than `expiry`; once per Top Shelf load.
    func removeExpiredFiles() {
        let directory = directory
        let fileManager = FileManager.default
        guard let files = try? fileManager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }
        for file in files {
            if let modified = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
               Date().timeIntervalSince(modified) > Self.expiry {
                try? fileManager.removeItem(at: file)
            }
        }
    }

    /// A stable file name for an image URL (64-bit FNV-1a).
    private static func fileName(for key: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in key.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(hash, radix: 16) + ".img"
    }
}
