import Foundation

public enum SafeTree {
    public static func children(_ root: URL, includeHidden: Bool = false) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: includeHidden ? [] : [.skipsHiddenFiles]).sorted { $0.path < $1.path }
    }
    public static func isDirectory(_ url: URL) -> Bool { (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
    public static func validate(_ url: URL) throws {
        var path = url.standardizedFileURL
        while path.path != "/" {
            if ["/var", "/tmp", "/etc"].contains(path.path), (try? FileManager.default.destinationOfSymbolicLink(atPath: path.path)) == "private" + path.path { path.deleteLastPathComponent(); continue }
            if (try? FileManager.default.attributesOfItem(atPath: path.path)[.type] as? FileAttributeType) == .typeSymbolicLink { throw MachineError.invalid("Symbolic links are not supported in imported content: \(path.lastPathComponent)") }
            path.deleteLastPathComponent()
        }
    }
    public static func walk(_ root: URL, includeHidden: Bool = false, visit: (URL) throws -> Bool) throws {
        try Task.checkCancellation(); try validate(root)
        guard try visit(root), isDirectory(root) else { return }
        for child in try children(root, includeHidden: includeHidden) { try walk(child, includeHidden: includeHidden, visit: visit) }
    }
    public static func byteCount(_ root: URL) throws -> Int64 {
        var bytes: Int64 = 0
        try walk(root, includeHidden: true) { url in
            if !isDirectory(url) { bytes += Int64(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) }
            return true
        }; return bytes
    }
}
public enum SourceDiscoveryService {
    public static func discover(_ urls: [URL], onError: ((URL, Error) -> Void)? = nil) throws -> [SourceArtifact] {
        var result: [SourceArtifact] = []; var seen = Set<String>()
        func scan(_ url: URL) throws {
            try Task.checkCancellation(); try SafeTree.validate(url)
            guard seen.insert(url.standardizedFileURL.path).inserted else { return }
            switch url.pathExtension.lowercased() {
            case "iso": result.append(SourceArtifact(url: url, type: .iso)); return
            case "pkg": result.append(SourceArtifact(url: url, type: .pkg)); return
            default: break
            }
            guard SafeTree.isDirectory(url) else { return }
            if LibraryRootDetector.isRoot(url) { result.append(SourceArtifact(url: url, type: .folder)); return }
            for child in try SafeTree.children(url) {
                do { try scan(child) }
                catch is CancellationError { throw CancellationError() }
                catch { if let onError { onError(child, error) } else { throw error } }
            }
        }
        for url in urls {
            do { try scan(url) }
            catch is CancellationError { throw CancellationError() }
            catch { if let onError { onError(url, error) } else { throw error } }
        }; return result
    }
}
public enum LibraryRootDetector {
    static let ignored: Set<String> = ["scripts", "resources", "contents", "packageinfo", "__macosx", "service center", "service centre"]
    public static func isRoot(_ url: URL) -> Bool {
        SafeTree.isDirectory(url) && !ignored.contains(url.lastPathComponent.lowercased()) && (url.lastPathComponent.lowercased() != "library" && url.lastPathComponent.lowercased().contains("library") && url.pathExtension.lowercased() != "pkg" || SafeTree.isDirectory(url.appendingPathComponent("PAResources")))
    }
    public static func roots(in root: URL, packageName: String? = nil) throws -> [URL] {
        var found: [URL] = []
        try SafeTree.walk(root) { url in
            if isRoot(url) { found.append(url); return false }
            return !["scripts", "__macosx"].contains(url.lastPathComponent.lowercased())
        }
        if found.isEmpty, packageName?.lowercased().contains("library") == true {
            func unwrap(_ url: URL) throws {
                let children = try SafeTree.children(url).filter { SafeTree.isDirectory($0) && !ignored.contains($0.lastPathComponent.lowercased()) }
                for child in children {
                    if child.lastPathComponent.lowercased() == "payload" || child.pathExtension.lowercased() == "pkg" { try unwrap(child) }
                    else if ["library", "users", "shared", "application support", "native instruments"].contains(child.lastPathComponent.lowercased()) { try unwrap(child) }
                    else { found.append(child) }
                }
            }; try unwrap(root)
        }; return found
    }
}
public enum ArtworkService {
    public static func find(in root: URL) throws -> URL? {
        var images: [URL] = []
        let resources = root.appendingPathComponent("PAResources/image")
        guard SafeTree.isDirectory(resources) else { return nil }
        try SafeTree.walk(resources) { url in
            if ["png", "jpg", "jpeg"].contains(url.pathExtension.lowercased()) { images.append(url) }; return true
        }
        return images.first { $0.lastPathComponent.lowercased() == "mst_artwork.png" } ?? images.first
    }
}
