import Foundation
import CryptoKit
import ImageIO

/// Download cache only; decoding and in-memory thumbnails remain in ArtworkThumbnailCache.
public actor OfficialArtworkCache {
    public static let shared = OfficialArtworkCache()
    private let root: URL
    private let fetch: CatalogueService.Fetch
    private let budget: Int
    private var inFlight: [String: Task<URL?, Never>] = [:]
    private var failed: [String: Date] = [:]
    private var active = 0
    private var generation = UUID()
    public init(root: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Maschinery/OfficialArtwork"), budget: Int = 128 * 1024 * 1024, fetch: @escaping CatalogueService.Fetch = { try await CatalogueHTTP.fetch($0) }) {
        self.root = root; self.fetch = fetch; self.budget = budget
    }
    public static func validImage(_ data: Data) -> Bool {
        guard !data.isEmpty, data.count <= 8 * 1024 * 1024,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int,
              w >= 32, h >= 32, w <= 8192, h <= 8192, w * h <= 40_000_000 else { return false }
        return true
    }
    public func file(for url: URL?, offline: Bool) async -> URL? {
        guard let url, CatalogueURL.isArtwork(url), !Task.isCancelled else { return nil }
        let key = SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
        let target = root.appendingPathComponent(key + ".image")
        if FileManager.default.fileExists(atPath: target.path), (try? SafeTree.validate(target)) != nil,
           let attributes = try? target.resourceValues(forKeys: [.fileSizeKey]), let size = attributes.fileSize, size <= 8 * 1024 * 1024,
           let data = try? Data(contentsOf: target), Self.validImage(data) {
            // Avoid invalidating the thumbnail cache's mtime key on every scroll.
            if let modified = try? target.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
               Date().timeIntervalSince(modified) > 3600 {
                try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: target.path)
            }
            return target
        }
        guard !offline, failed[key].map({ Date().timeIntervalSince($0) >= 3600 }) ?? true else { return nil }
        if let request = inFlight[key] { return await request.value }
        let epoch = generation
        let request = Task { await self.download(url, to: target) }
        inFlight[key] = request
        let result = await request.value
        if epoch == generation {
            inFlight[key] = nil
            if result == nil { failed[key] = Date() }
        }
        return result
    }
    private func download(_ url: URL, to target: URL) async -> URL? {
        do {
            while active >= 3 { try await Task.sleep(for: .milliseconds(100)) }
            try Task.checkCancellation(); active += 1
            defer { active -= 1 }
            let data = try await fetch(url)
            try Task.checkCancellation()
            guard data.count <= budget, Self.validImage(data) else { return nil }
            try SafeTree.validate(root)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try data.write(to: target, options: .atomic)
            try prune(protecting: target)
            return target
        } catch { return nil }
    }
    private func prune(protecting target: URL) throws {
        let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]).filter { $0.pathExtension == "image" }
        var entries = try files.map { url in (url, try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])) }
        entries.sort { ($0.1.contentModificationDate ?? .distantPast) < ($1.1.contentModificationDate ?? .distantPast) }
        var size = entries.reduce(0) { $0 + ($1.1.fileSize ?? 0) }
        for (file, values) in entries where size > budget && file != target {
            try FileManager.default.removeItem(at: file); size -= values.fileSize ?? 0
        }
    }
    public func cancelDownloads() { generation = UUID(); for task in inFlight.values { task.cancel() }; inFlight.removeAll() }
}
