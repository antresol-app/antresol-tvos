import AntresolKit
import Foundation

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

    /// Local files for server image paths; paths that fail to download are left out.
    func files(for paths: [String]) async -> [String: URL] {
        let directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        removeExpiredFiles(in: directory)

        return await withTaskGroup(of: (String, URL?).self) { group in
            for path in Set(paths) {
                group.addTask { (path, await file(for: path, in: directory)) }
            }
            var result: [String: URL] = [:]
            for await (path, file) in group {
                if let file { result[path] = file }
            }
            return result
        }
    }

    private func file(for path: String, in directory: URL) async -> URL? {
        let file = directory.appendingPathComponent(Self.fileName(for: path))
        if let modified = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
           Date().timeIntervalSince(modified) < Self.freshness {
            return file
        }
        guard let url = client.urls.image(path) else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 15)
        for (field, value) in client.authorizationHeaders(for: url) {
            request.setValue(value, forHTTPHeaderField: field)
        }
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200, !data.isEmpty else {
                return FileManager.default.fileExists(atPath: file.path) ? file : nil
            }
            try data.write(to: file, options: .atomic)
            return file
        } catch {
            // Offline: a stale copy is better than no artwork.
            return FileManager.default.fileExists(atPath: file.path) ? file : nil
        }
    }

    private func removeExpiredFiles(in directory: URL) {
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

    /// A stable file name for a server path (64-bit FNV-1a).
    private static func fileName(for path: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in path.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(hash, radix: 16) + ".img"
    }
}
