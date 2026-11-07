import Foundation
public enum LibraryIssue: String, Codable, Sendable { case missingContent = "Missing Content", unreadable = "Permission Problem", missingXML = "Missing XML", missingArtwork = "Missing Artwork", missingResources = "Missing PAResources", registration = "Registration Problem", duplicate = "Conflicting Registration" }
public struct InstalledLibrary: Identifiable, Sendable {
    public let id: URL
    public let name: String
    public var nativeIDs: [String] = []
    public let content: URL?
    public let version: String?
    public let artwork: URL?
    public var issues: [LibraryIssue]
    public var serviceCenter: URL = URL(fileURLWithPath: "/Library/Application Support/Native Instruments/Service Center")
    public var critical: Bool { issues.contains(.missingContent) || issues.contains(.unreadable) || issues.contains(.registration) || issues.contains(.duplicate) }
}
public enum ExistingLibraryService {
    // Native Access also writes legacy volume:folder: paths.
    static func contentURL(_ path: String) -> URL? {
        if path.hasPrefix("/"), path != "/" { return URL(fileURLWithPath: path) }
        var parts = path.components(separatedBy: ":")
        guard parts.count > 1, let volume = parts.first, !volume.isEmpty else { return nil }
        parts.removeFirst()
        if parts.last == "" { parts.removeLast() }
        guard !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              !volume.contains("/"), volume != ".", volume != ".." else { return nil }
        let startup = URL(fileURLWithPath: "/")
        let startupName = try? startup.resourceValues(forKeys: [.volumeNameKey]).volumeName
        let base = volume == startupName ? startup : URL(fileURLWithPath: "/Volumes").appendingPathComponent(volume)
        return parts.reduce(base) { $0.appendingPathComponent($1.replacingOccurrences(of: "/", with: ":")) }
    }

    static func isMaschineLibrary(_ library: InstalledLibrary, catalogueNames: Set<String>) throws -> Bool {
        let key = ProductName.key(library.name)
        // Host applications and base factory libraries are not expansions, even
        // when their support folders contain Groups/Sounds or host relevance.
        let hosts = #"^(?:kontakt[0-9]*(?:player|factory(?:library|selection)?[0-9]*)?|maschine[0-9]*(?:factory(?:library|selection)?|selection)?|kompletekontrol[0-9]*)$"#
        guard key.range(of: hosts, options: .regularExpression) == nil else { return false }
        var nativeMetadata = false
        let xml = library.serviceCenter.appendingPathComponent(library.name + ".xml")
        if let data = try? Data(contentsOf: xml), let records = try? MetadataXML.parse(data, source: .embedded) {
            let matching = records.filter { ProductName.key($0.name) == key }
            if matching.count == 1, let document = try? XMLDocument(data: matching[0].xml, options: [.nodeLoadExternalEntitiesNever]),
               let nodes = try? document.nodes(forXPath: "//FactoryLibrary/Relevance/Application[@nativeContent='true']") {
                nativeMetadata = nodes.contains { $0.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "maschine" }
            }
        }
        guard let content = library.content, SafeTree.isDirectory(content) else {
            // Current catalogue identity or product-scoped native metadata keeps
            // genuine missing/offline expansions available for Locate Content.
            return nativeMetadata || catalogueNames.contains(key)
        }
        if nativeMetadata { return true }
        for folder in ["Groups", "Sounds"] {
            let root = content.appendingPathComponent(folder)
            guard SafeTree.isDirectory(root), (try? SafeTree.validate(root)) != nil,
                  let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            var visited = 0
            for case let file as URL in enumerator {
                try Task.checkCancellation()
                visited += 1
                if visited > 25_000 { break }
                if enumerator.level > 16 { enumerator.skipDescendants(); continue }
                guard let info = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]) else { continue }
                if info.isSymbolicLink == true { enumerator.skipDescendants(); continue }
                // Kontakt uses .nkg; NKS plug-ins use other preset formats.
                // Retain native Maschine 1 as well as current Maschine formats.
                if info.isRegularFile == true, (info.fileSize ?? 0) > 0,
                   ["mxgrp", "mxsnd", "mgrp", "msnd"].contains(file.pathExtension.lowercased()) { return true }
            }
        }
        return false
    }

    public static func audit(preferences: URL = URL(fileURLWithPath: "/Library/Preferences"), serviceCenter: URL = URL(fileURLWithPath: "/Library/Application Support/Native Instruments/Service Center"), resources: URL = URL(fileURLWithPath: "/Users/Shared/NI Resources/image"), maschineOnly: Bool = false, onLibrary: @Sendable (InstalledLibrary) -> Void = { _ in }, onProgress: @Sendable (Int, Int) -> Void = { _, _ in }) throws -> [InstalledLibrary] {
        let catalogueNames: Set<String> = maschineOnly ? Set((try? CatalogueSnapshot.bundled().products.map { ProductName.key($0.name) }) ?? []) : []
        let registrations = try SafeTree.children(preferences).filter { $0.lastPathComponent.hasPrefix("com.native-instruments.") && $0.pathExtension == "plist" }
        onProgress(0, registrations.count)
        var libraries = try registrations.enumerated().compactMap { index, plist -> InstalledLibrary? in
            try Task.checkCancellation()
            defer { if !Task.isCancelled { onProgress(index + 1, registrations.count) } }
            let name = String(plist.deletingPathExtension().lastPathComponent.dropFirst("com.native-instruments.".count))
            var issues: [LibraryIssue] = []; var content: URL?; var version: String?
            do {
                let values = try PropertyListSerialization.propertyList(from: Data(contentsOf: plist), format: nil) as? [String: Any]
                if let path = values?["ContentDir"] as? String, let resolved = contentURL(path) { content = resolved } else { issues.append(.registration) }
                version = values?["ContentVersion"] as? String
            } catch { issues.append(.registration) }
            if maschineOnly {
                let candidate = InstalledLibrary(id: plist, name: name, content: content, version: version, artwork: nil, issues: issues, serviceCenter: serviceCenter)
                if try !isMaschineLibrary(candidate, catalogueNames: catalogueNames) { return nil }
            }
            if let content {
                if !SafeTree.isDirectory(content) { issues.append(.missingContent) }
                else {
                    if !FileManager.default.isReadableFile(atPath: content.path) { issues.append(.unreadable) }
                    do {
                        try SafeTree.walk(content) { url in
                            let readable = FileManager.default.isReadableFile(atPath: url.path)
                            let traversable = !SafeTree.isDirectory(url) || FileManager.default.isExecutableFile(atPath: url.path)
                            if (!readable || !traversable) && !issues.contains(.unreadable) { issues.append(.unreadable) }
                            return true
                        }
                    } catch is CancellationError { throw CancellationError() }
                    catch { if !issues.contains(.unreadable) { issues.append(.unreadable) } }
                    if !SafeTree.isDirectory(content.appendingPathComponent("PAResources")) { issues.append(.missingResources) }
                }
            }
            let xml = serviceCenter.appendingPathComponent(name + ".xml")
            // Service Center XML is optional for existing Native Access libraries.
            // Missing metadata alone does not indicate broken registration.
            if FileManager.default.isReadableFile(atPath: xml.path) {
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
            var library = InstalledLibrary(id: plist, name: name, content: content, version: version, artwork: artwork, issues: issues, serviceCenter: serviceCenter)
            // Only explicit NI identifiers are namespaced here. Store SKUs and
            // Shopify IDs must never be treated as NI registration identifiers.
            if let data = try? Data(contentsOf: xml), let records = try? MetadataXML.parse(data, source: .embedded),
               records.count == 1, ProductName.key(records[0].name) == ProductName.key(name),
               let document = try? XMLDocument(data: data, options: [.nodeLoadExternalEntitiesNever]) {
                for (tag, namespace) in [("UPID", "ni:upid:"), ("RegKey", "ni:regkey:")] {
                    if let nodes = try? document.nodes(forXPath: "//" + tag) {
                        library.nativeIDs += nodes.compactMap { $0.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.map { namespace + $0.lowercased() }
                    }
                }
            }
            onLibrary(library)
            return library
        }.sorted { $0.name < $1.name }
        try Task.checkCancellation()
        let identities = Dictionary(grouping: libraries, by: { ProductName.key($0.name) })
        let paths = Dictionary(grouping: libraries.filter { $0.content != nil }, by: { $0.content!.standardizedFileURL.path })
        for i in libraries.indices {
            if identities[ProductName.key(libraries[i].name), default: []].count > 1 || libraries[i].content.map({ paths[$0.standardizedFileURL.path, default: []].count > 1 }) == true { libraries[i].issues.append(.duplicate) }
        }
        return libraries
    }
}
