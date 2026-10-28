import Foundation
import ImageIO

public struct ArtworkCandidate: Identifiable, Codable, Sendable, Equatable {
    public var id: URL { url }
    public let url: URL
    public let width: Int
    public let height: Int
    public let score: Int
    public let reasons: [String]
    public let rejectionReason: String?
    public var dimensions: String { width > 0 && height > 0 ? "\(width)x\(height)" : "unknown dimensions" }
}
public struct ArtworkDiscovery: Codable, Sendable, Equatable {
    public let consideredCount: Int
    public let plausibleCount: Int
    /// Best eight plausible candidates, descending score, retained for diagnostics/manual selection later.
    public let rankedCandidates: [ArtworkCandidate]
    /// Bounded diagnostics; malformed and tiny images cannot become fallbacks.
    public let rejectedCandidates: [ArtworkCandidate]
    public let warnings: [String]
    public var selected: ArtworkCandidate? { rankedCandidates.first }
    public var selectionReason: String {
        guard let selected else { return "No plausible artwork among \(consideredCount) images; using placeholder." }
        return "Highest score among \(plausibleCount) plausible images (\(consideredCount) considered). " + selected.reasons.joined(separator: "; ")
    }
}
public enum ArtworkService {
    static let extensions: Set<String> = ["png", "jpg", "jpeg", "tif", "tiff", "gif", "bmp", "heic", "heif", "webp", "jp2", "jpf", "jpx", "avif", "ico", "icns"]
    public static func find(in root: URL, productName: String? = nil) throws -> URL? {
        try discover(payloads: [root], productName: productName ?? ProductName.display(root.lastPathComponent)).selected?.url
    }
    public static func discover(payloads: [URL], productName: String, aliases: [String] = []) throws -> ArtworkDiscovery {
        try discoverImageRoots(payloads.map { $0.appendingPathComponent("PAResources/image") }, productName: productName, aliases: aliases + payloads.map(\.lastPathComponent))
    }
    static func discoverImageRoots(_ imageRoots: [URL], productName: String, aliases: [String] = []) throws -> ArtworkDiscovery {
        let product = ProductName.key(productName)
        let aliasKeys = Set(aliases.map(ProductName.key).filter { !$0.isEmpty })
        var seen = Set<String>(), candidates: [ArtworkCandidate] = [], warnings: [String] = []
        for imageRoot in imageRoots {
            try Task.checkCancellation()
            guard FileManager.default.fileExists(atPath: imageRoot.path) else { continue }
            do {
                try SafeTree.walk(imageRoot) { url in
                    if extensions.contains(url.pathExtension.lowercased()), !SafeTree.isDirectory(url), seen.insert(url.standardizedFileURL.path).inserted {
                        candidates.append(inspect(url, imageRoot: imageRoot, product: product, aliases: aliasKeys))
                    }
                    return true
                }
            } catch is CancellationError { throw CancellationError() }
            catch { warnings.append("Could not finish artwork search under \(imageRoot.path): \(error.localizedDescription)") }
        }
        let ranked = candidates.filter { $0.rejectionReason == nil }.sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            let lhs = Int64($0.width) * Int64($0.height), rhs = Int64($1.width) * Int64($1.height)
            return lhs == rhs ? $0.url.path < $1.url.path : lhs > rhs
        }
        let rejected = candidates.filter { $0.rejectionReason != nil }.sorted { $0.url.path < $1.url.path }
        return ArtworkDiscovery(consideredCount: candidates.count, plausibleCount: ranked.count, rankedCandidates: Array(ranked.prefix(8)), rejectedCandidates: Array(rejected.prefix(12)), warnings: warnings)
    }
    private static func inspect(_ url: URL, imageRoot: URL, product: String, aliases: Set<String>) -> ArtworkCandidate {
        let stem = url.deletingPathExtension().lastPathComponent.lowercased()
        let compact = stem.filter { $0.isLetter || $0.isNumber }
        var score = 20, reasons = ["decodable image +20"]
        func add(_ points: Int, _ reason: String) { score += points; reasons.append(reason + " \(points >= 0 ? "+" : "")\(points)") }
        if compact.contains("mstartwork") { add(65, "MST_artwork filename") }
        else {
            let terms = [("artwork", 35), ("cover", 32), ("expansion", 24), ("product", 22), ("library", 20), ("browser", 12), ("tile", 8)]
            if let best = terms.first(where: { stem.contains($0.0) }) { add(best.1, "\(best.0) filename") }
        }
        let undesirable = ["icon", "badge", "logo", "button", "sprite", "toolbar", "knob", "slider", "checkbox", "cursor", "glyph", "transport", "meter"]
        if let term = undesirable.first(where: { stem.contains($0) }) { add(-55, "\(term) / UI asset penalty") }
        let rootComponents = imageRoot.resolvingSymlinksInPath().pathComponents
        let directories = Array(url.deletingLastPathComponent().resolvingSymlinksInPath().pathComponents.dropFirst(rootComponents.count))
        if !product.isEmpty, directories.contains(where: { ProductName.key($0) == product }) { add(45, "normalized product directory match") }
        else if directories.contains(where: { aliases.contains(ProductName.key($0)) }) { add(30, "normalized payload alias directory match") }
        if directories.contains(where: { ["ui", "icons", "buttons", "sprites", "controls", "interface", "toolbar"].contains($0.lowercased()) }) { add(-35, "UI directory penalty") }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary), CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              var width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              var height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue else {
            return ArtworkCandidate(url: url, width: 0, height: 0, score: score, reasons: reasons.filter { $0 != "decodable image +20" }, rejectionReason: "unreadable or unsupported image metadata")
        }
        if let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue, (5...8).contains(orientation) { swap(&width, &height) }
        func reject(_ reason: String) -> ArtworkCandidate { ArtworkCandidate(url: url, width: width, height: height, score: score, reasons: reasons, rejectionReason: reason) }
        guard width >= 48, height >= 48, max(width, height) >= 96 else { return reject("tiny dimensions") }
        guard width <= 50_000, height <= 50_000, Int64(width) * Int64(height) <= 200_000_000 else { return reject("implausibly large dimensions") }
        let ratio = Double(width) / Double(height)
        guard (0.2...6.0).contains(ratio) else { return reject("extreme aspect ratio suggests UI strip") }
        let area = width * height
        if area >= 512 * 512 { add(22, "large useful dimensions") }
        else if area >= 256 * 128 { add(14, "useful dimensions") }
        else if area < 128 * 128 { add(-15, "small dimensions") }
        if (1.35...2.5).contains(ratio) { add(22, "Maschine browser landscape aspect ratio") }
        else if (1.1...3.0).contains(ratio) { add(10, "landscape aspect ratio") }
        else if (0.9...1.1).contains(ratio) { add(4, "square cover aspect ratio") }
        else { add(-15, "portrait or narrow aspect ratio") }
        return ArtworkCandidate(url: url, width: width, height: height, score: score, reasons: reasons, rejectionReason: nil)
    }
    public static func log(_ report: ArtworkDiscovery, product: String, to logger: LoggingService) async {
        await logger.log(.info, "Artwork: considered \(report.consideredCount) images for \(product)")
        if let selected = report.selected {
            await logger.log(.info, "Artwork: selected \(selected.url.path) (\(selected.dimensions), score \(selected.score)) [\(product)]")
            await logger.log(.debug, "Artwork: \(report.selectionReason) [\(product)]")
        } else { await logger.log(.info, "Artwork: no plausible image; using placeholder [\(product)]") }
        for candidate in report.rejectedCandidates {
            await logger.log(.debug, "Artwork: rejected \(candidate.url.path) (\(candidate.dimensions), \(candidate.rejectionReason ?? ""), \(candidate.reasons.joined(separator: "; "))) [\(product)]")
        }
        for candidate in report.rankedCandidates.dropFirst().prefix(4) {
            await logger.log(.debug, "Artwork: alternate \(candidate.url.path) (score \(candidate.score): \(candidate.reasons.joined(separator: "; "))) [\(product)]")
        }
        if report.consideredCount - report.plausibleCount > report.rejectedCandidates.count { await logger.log(.debug, "Artwork: additional rejected images omitted from diagnostic sample [\(product)]") }
        for warning in report.warnings { await logger.log(.warning, "Artwork: \(warning) [\(product)]") }
    }
}
