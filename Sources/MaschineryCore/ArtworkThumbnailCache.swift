import Foundation
import ImageIO
import Darwin

/// CGImage is immutable; only already-decoded, bounded thumbnails cross actor boundaries.
public struct ArtworkThumbnail: @unchecked Sendable {
    public let image: CGImage
}
private final class ThumbnailBox: NSObject {
    let value: ArtworkThumbnail
    init(_ value: ArtworkThumbnail) { self.value = value }
}
/// Serial, non-main actor bounds disk/decoder concurrency and shares results across all artwork views.
public actor ArtworkThumbnailCache {
    public static let shared = ArtworkThumbnailCache()
    private let cache = NSCache<NSString, ThumbnailBox>()
    private(set) var decodeCount = 0
    private(set) var lastDecodeWasOnMainThread = false
    public init() { cache.countLimit = 128; cache.totalCostLimit = 32 * 1024 * 1024 }
    public func thumbnail(at url: URL, maxPixelSize: Int = 512) -> ArtworkThumbnail? {
        guard !Task.isCancelled, (try? SafeTree.validate(url)) != nil else { return nil }
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return nil }
        let pixels = min(max(maxPixelSize, 32), 1024)
        let key = "\(url.standardizedFileURL.path)|\(info.st_ino)|\(info.st_size)|\(info.st_mtimespec.tv_sec).\(info.st_mtimespec.tv_nsec)|\(pixels)" as NSString
        if let hit = cache.object(forKey: key) { return hit.value }
        lastDecodeWasOnMainThread = Thread.isMainThread; decodeCount += 1
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: pixels,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary), !Task.isCancelled else { return nil }
        let thumbnail = ArtworkThumbnail(image: image)
        cache.setObject(ThumbnailBox(thumbnail), forKey: key, cost: image.bytesPerRow * image.height)
        return thumbnail
    }
    public func clear() { cache.removeAllObjects() }
}
