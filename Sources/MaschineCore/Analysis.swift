import Foundation

/// Owns extracted payloads until the queue is discarded. ISO content is copied here before detaching.
public final class AnalysisSession: Sendable {
    public let workspace: URL
    public init() throws {
        workspace = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("MaschineMachine-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    }
    deinit { try? FileManager.default.removeItem(at: workspace) }
}
public struct AnalysisResult: Sendable { public let session: AnalysisSession; public var candidates: [ExpansionCandidate] }
public struct ExpansionAnalyzer: Sendable {
    public let log: LoggingService
    public let hints: ProductHintsService
    public init(log: LoggingService, hints: ProductHintsService = ProductHintsService()) { self.log = log; self.hints = hints }
    public func analyze(_ urls: [URL], destination: URL, explicit: [RegistrationMetadata] = [], offline: Bool = false) async throws -> AnalysisResult {
        let session = try AnalysisSession()
        let sources = try SourceDiscoveryService.discover(urls)
        var trees: [(URL, SourceArtifact, String?)] = []
        let packages = PackageExtractionService(log: log)
        for source in sources {
            try Task.checkCancellation()
            await log.log(.info, "Analysing \(source.url.lastPathComponent)")
            do {
                switch source.type {
                case .folder: trees.append((source.url, source, nil))
                case .pkg: trees.append((try await packages.expand(source.url, workspace: session.workspace), source, source.url.lastPathComponent))
                case .iso:
                    let iso = ISOService(); let mounts = try await iso.attach(source.url)
                    var failure: Error?
                    do {
                        for mount in mounts {
                            guard !(try SafeTree.children(mount)).isEmpty else { throw MachineError.invalid("Mounted image is empty") }
                            let components = try SourceDiscoveryService.discover([mount])
                            for component in components {
                                if component.type == .pkg { trees.append((try await packages.expand(component.url, workspace: session.workspace), source, component.url.lastPathComponent)) }
                                else if component.type == .folder {
                                    let copy = session.workspace.appendingPathComponent(UUID().uuidString).appendingPathComponent(component.url.lastPathComponent)
                                    try FileManager.default.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: false)
                                    try SafeTree.walk(component.url) { _ in true }; try FileManager.default.copyItem(at: component.url, to: copy)
                                    trees.append((copy, source, nil))
                                }
                            }
                            // Cache loose XML before detaching, including metadata outside library roots.
                            let xmlRoot = session.workspace.appendingPathComponent(UUID().uuidString)
                            try FileManager.default.createDirectory(at: xmlRoot, withIntermediateDirectories: false)
                            try SafeTree.walk(mount) { url in
                                if url.pathExtension.lowercased() == "pkg" { return false }
                                if url.pathExtension.lowercased() == "xml" { try FileManager.default.copyItem(at: url, to: xmlRoot.appendingPathComponent(UUID().uuidString + ".xml")) }; return true
                            }; trees.append((xmlRoot, source, nil))
                        }
                    } catch { failure = error }
                    // A detached task does not inherit cancellation; cleanup must run even after Cancel.
                    for mount in mounts {
                        do { try await Task.detached { try await iso.detach(mount) }.value }
                        catch { await log.log(.error, "Could not detach \(mount.path): \(error.localizedDescription)"); if failure == nil { failure = error } }
                    }
                    if let failure { throw failure }
                }
            } catch is CancellationError { throw CancellationError() }
            catch { await log.log(.error, "\(source.url.lastPathComponent): \(error.localizedDescription)") }
        }
        var records = explicit
        var xmlDiagnostics: [String] = []
        for (tree, _, _) in trees {
            try SafeTree.walk(tree) { url in
                if url.pathExtension.lowercased() == "xml" {
                    do { records += try MetadataXML.parse(Data(contentsOf: url), source: .embedded) }
                    catch { xmlDiagnostics.append("XML could not be read (\(url.lastPathComponent)): \(error.localizedDescription)") }
                }; return true
            }
        }
        for diagnostic in xmlDiagnostics { await log.log(.warning, diagnostic) }
        var grouped: [String: ExpansionCandidate] = [:]
        for (tree, source, package) in trees {
            for root in try LibraryRootDetector.roots(in: tree, packageName: package) {
                let name = ProductName.display(root.lastPathComponent), key = ProductName.key(name)
                guard !key.isEmpty else { continue }
                if var candidate = grouped[key] {
                    if !candidate.payloads.contains(root) { candidate.payloads.append(root); candidate.size += try SafeTree.byteCount(root) }
                    if !candidate.sources.contains(source) { candidate.sources.append(source) }; grouped[key] = candidate
                } else {
                    grouped[key] = ExpansionCandidate(name: name, sources: [source], payloads: [root], destination: destination.appendingPathComponent(name), size: try SafeTree.byteCount(root), artwork: try ArtworkService.find(in: root))
                }
            }
        }
        let needsOnline = grouped.values.contains { if case .unresolved = MetadataMatchingService.match($0.name, in: records) { return true }; return false }
        if needsOnline && !offline {
            do { records += try await hints.records(offline: false); await log.log(.info, "ProductHints metadata loaded") }
            catch { await log.log(.warning, "ProductHints unavailable: \(error.localizedDescription)") }
        }
        var candidates = Array(grouped.values)
        for index in candidates.indices {
            switch MetadataMatchingService.match(candidates[index].name, in: records) {
            case .matched(let metadata): candidates[index].metadata = metadata; candidates[index].name = metadata.name
            case .ambiguous: candidates[index].warnings.append("Ambiguous registration metadata. Choose XML before installing.")
            case .unresolved: candidates[index].warnings.append("Registration metadata unavailable. Import XML or use Extract Only.")
            }
            if candidates[index].artwork == nil { candidates[index].warnings.append("Artwork unavailable") }
            if FileManager.default.fileExists(atPath: candidates[index].destination.path) { candidates[index].state = .conflict }
            else if !candidates[index].warnings.isEmpty { candidates[index].state = .warning }
        }
        await log.log(.success, "Analysis complete: \(candidates.count) logical expansions from \(sources.count) sources")
        return AnalysisResult(session: session, candidates: candidates.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending })
    }
}
