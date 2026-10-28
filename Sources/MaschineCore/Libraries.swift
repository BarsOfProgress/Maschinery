import Foundation
public enum LibraryIssue: String, Codable, Sendable { case missingContent = "Missing Content", unreadable = "Permission Problem", missingXML = "Missing XML", missingArtwork = "Missing Artwork", missingResources = "Missing PAResources", registration = "Registration Problem", duplicate = "Conflicting Registration" }
public struct InstalledLibrary: Identifiable, Sendable {
    public let id: URL
    public let name: String
    public let content: URL?
    public let version: String?
    public let artwork: URL?
    public var issues: [LibraryIssue]
    public var serviceCenter: URL = URL(fileURLWithPath: "/Library/Application Support/Native Instruments/Service Center")
    public var critical: Bool { issues.contains(.missingContent) || issues.contains(.unreadable) || issues.contains(.registration) || issues.contains(.duplicate) }
}
public enum ExistingLibraryService {
    public static func audit(preferences: URL = URL(fileURLWithPath: "/Library/Preferences"), serviceCenter: URL = URL(fileURLWithPath: "/Library/Application Support/Native Instruments/Service Center"), resources: URL = URL(fileURLWithPath: "/Users/Shared/NI Resources/image")) throws -> [InstalledLibrary] {
        var libraries = try SafeTree.children(preferences).filter { $0.lastPathComponent.hasPrefix("com.native-instruments.") && $0.pathExtension == "plist" }.map { plist in
            try Task.checkCancellation()
            let name = String(plist.deletingPathExtension().lastPathComponent.dropFirst("com.native-instruments.".count))
            var issues: [LibraryIssue] = []; var content: URL?; var version: String?
            do {
                let values = try PropertyListSerialization.propertyList(from: Data(contentsOf: plist), format: nil) as? [String: Any]
                if let path = values?["ContentDir"] as? String, path.hasPrefix("/"), path != "/" { content = URL(fileURLWithPath: path) } else { issues.append(.registration) }
                version = values?["ContentVersion"] as? String
            } catch { issues.append(.registration) }
            if let content {
                if !SafeTree.isDirectory(content) { issues.append(.missingContent) }
                else {
                    if !FileManager.default.isReadableFile(atPath: content.path) { issues.append(.unreadable) }
                    do {
                        try SafeTree.walk(content) { url in
                            let mode = (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue ?? 0
                            let required = SafeTree.isDirectory(url) ? 0o500 : 0o400
                            if mode & required != required && !issues.contains(.unreadable) { issues.append(.unreadable) }
                            return true
                        }
                    } catch { if !issues.contains(.unreadable) { issues.append(.unreadable) } }
                    if !SafeTree.isDirectory(content.appendingPathComponent("PAResources")) { issues.append(.missingResources) }
                }
            }
            let xml = serviceCenter.appendingPathComponent(name + ".xml")
            if !FileManager.default.isReadableFile(atPath: xml.path) { issues.append(.missingXML) }
            else {
                do {
                    let records = try MetadataXML.read(xml, source: .embedded)
                    if !records.isEmpty && !records.contains(where: { ProductName.key($0.name) == ProductName.key(name) }) { issues.append(.registration) }
                } catch { issues.append(.registration) }
            }
            let localArtwork = try? ArtworkService.find(in: content ?? URL(fileURLWithPath: "/nonexistent"), productName: name)
            let productImages = resources.appendingPathComponent(name)
            let resourceArtwork = localArtwork == nil ? try? ArtworkService.discoverImageRoots([productImages], productName: name).selected?.url : nil
            let artwork = localArtwork ?? resourceArtwork
            // This existing health check reports installed resource presence, not image decoding validity.
            // Display selection separately validates metadata and ranks plausible images.
            var hasInstalledImage = false
            if SafeTree.isDirectory(productImages) {
                do {
                    try SafeTree.walk(productImages) { url in
                        if !SafeTree.isDirectory(url), ArtworkService.extensions.contains(url.pathExtension.lowercased()), FileManager.default.isReadableFile(atPath: url.path) { hasInstalledImage = true }
                        return true
                    }
                } catch is CancellationError { throw CancellationError() }
                catch { if !issues.contains(.unreadable) { issues.append(.unreadable) } }
            }
            if !hasInstalledImage { issues.append(.missingArtwork) }
            return InstalledLibrary(id: plist, name: name, content: content, version: version, artwork: artwork, issues: issues, serviceCenter: serviceCenter)
        }.sorted { $0.name < $1.name }
        let identities = Dictionary(grouping: libraries, by: { ProductName.key($0.name) })
        let paths = Dictionary(grouping: libraries.filter { $0.content != nil }, by: { $0.content!.standardizedFileURL.path })
        for i in libraries.indices {
            if identities[ProductName.key(libraries[i].name), default: []].count > 1 || libraries[i].content.map({ paths[$0.standardizedFileURL.path, default: []].count > 1 }) == true { libraries[i].issues.append(.duplicate) }
        }
        return libraries
    }
}
