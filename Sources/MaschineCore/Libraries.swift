import Foundation
public enum LibraryIssue: String, Codable, Sendable { case missingContent = "Missing Content", unreadable = "Permission Problem", missingXML = "Missing XML", missingArtwork = "Missing Artwork", missingResources = "Missing PAResources", registration = "Registration Problem" }
public struct InstalledLibrary: Identifiable, Sendable {
    public let id: URL
    public let name: String
    public let content: URL?
    public let version: String?
    public let artwork: URL?
    public let issues: [LibraryIssue]
    public var critical: Bool { issues.contains(.missingContent) || issues.contains(.unreadable) || issues.contains(.registration) }
}
public enum ExistingLibraryService {
    public static func audit(preferences: URL = URL(fileURLWithPath: "/Library/Preferences"), serviceCenter: URL = URL(fileURLWithPath: "/Library/Application Support/Native Instruments/Service Center"), resources: URL = URL(fileURLWithPath: "/Users/Shared/NI Resources/image")) throws -> [InstalledLibrary] {
        try SafeTree.children(preferences).filter { $0.lastPathComponent.hasPrefix("com.native-instruments.") && $0.pathExtension == "plist" }.map { plist in
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
                    if !SafeTree.isDirectory(content.appendingPathComponent("PAResources")) { issues.append(.missingResources) }
                }
            }
            if !FileManager.default.isReadableFile(atPath: serviceCenter.appendingPathComponent(name + ".xml").path) { issues.append(.missingXML) }
            let artwork = try? ArtworkService.find(in: content ?? URL(fileURLWithPath: "/nonexistent"))
            let installedArtwork = resources.appendingPathComponent(name).appendingPathComponent("MST_artwork.png")
            if !FileManager.default.isReadableFile(atPath: installedArtwork.path) { issues.append(.missingArtwork) }
            return InstalledLibrary(id: plist, name: name, content: content, version: version, artwork: artwork, issues: issues)
        }.sorted { $0.name < $1.name }
    }
}
