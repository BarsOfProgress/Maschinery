import Foundation

/// Owns extracted payloads until the queue is discarded. ISO content is copied here before detaching.
public final class AnalysisSession: Sendable {
    public let workspace: URL
    public init() throws {
        try FileManager.default.createDirectory(at: AnalysisRecovery.root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try SafeTree.validate(AnalysisRecovery.root)
        workspace = AnalysisRecovery.root.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try Data(String(ProcessInfo.processInfo.processIdentifier).utf8).write(to: workspace.appendingPathComponent(".owner-pid"))
    }
    deinit { try? FileManager.default.removeItem(at: workspace) }
}
public struct AnalysisResult: Sendable { public let session: AnalysisSession; public var candidates: [ExpansionCandidate] }
public struct ExpansionAnalyzer: Sendable {
    public let log: LoggingService
    public let hints: ProductHintsService
    public let runner: any ProcessRunning
    public init(log: LoggingService, hints: ProductHintsService = ProductHintsService(), runner: any ProcessRunning = ProcessRunner()) { self.log = log; self.hints = hints; self.runner = runner }
    public func analyze(_ urls: [URL], destination: URL, explicit: [RegistrationMetadata] = [], offline: Bool = false) async throws -> AnalysisResult {
        let session = try AnalysisSession()
        var trees: [(URL, SourceArtifact, String?)] = []
        var failures: [ExpansionCandidate] = []
        func failed(_ source: SourceArtifact, _ error: Error) -> ExpansionCandidate {
            ExpansionCandidate(name: ProductName.display(source.url.deletingPathExtension().lastPathComponent), sources: [source], payloads: [], destination: destination.appendingPathComponent(source.url.deletingPathExtension().lastPathComponent), warnings: [error.localizedDescription], state: .failed)
        }
        let sources = try SourceDiscoveryService.discover(urls, onError: { url, error in
            let type: SourceType = url.pathExtension.lowercased() == "pkg" ? .pkg : url.pathExtension.lowercased() == "iso" ? .iso : .folder
            failures.append(failed(SourceArtifact(url: url, type: type), error))
        })
        for candidate in failures { await log.log(.error, candidate.name + ": " + candidate.warnings.joined(separator: "; ")) }
        let packages = PackageExtractionService(runner: runner, log: log)
        for source in sources {
            try Task.checkCancellation()
            await log.log(.info, "Analysing \(source.url.lastPathComponent)")
            do {
                switch source.type {
                case .folder: try SafeTree.walk(source.url) { _ in true }; trees.append((source.url, source, nil))
                case .pkg: trees.append((try await packages.expand(source.url, workspace: session.workspace), source, source.url.lastPathComponent))
                case .iso:
                    let iso = ISOService(runner: runner); let mounts = try await iso.attach(source.url)
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
                                    try await InstallationService(log: log).copyTree(component.url, to: copy) { _ in }
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
            catch { failures.append(failed(source, error)); await log.log(.error, "\(source.url.lastPathComponent): \(error.localizedDescription)") }
        }
        var records = explicit
        var xmlDiagnostics: [String] = []
        for (tree, _, _) in trees {
            try SafeTree.walk(tree) { url in
                if url.pathExtension.lowercased() == "xml" {
                    do { records += try MetadataXML.read(url, source: .embedded) }
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
                    grouped[key] = ExpansionCandidate(name: name, sources: [source], payloads: [root], destination: destination.appendingPathComponent(name), size: try SafeTree.byteCount(root))
                }
            }
        }
        let needsOnline = grouped.values.contains { if case .unresolved = MetadataMatchingService.match($0.name, in: records) { return true }; return false }
        if needsOnline && !offline {
            do { records += try await hints.records(offline: false); await log.log(.info, "ProductHints metadata loaded") }
            catch { await log.log(.warning, "ProductHints unavailable: \(error.localizedDescription)") }
        }
        var candidates = Array(grouped.values) + failures
        for index in candidates.indices {
            if candidates[index].state == .failed { continue }
            switch MetadataMatchingService.match(candidates[index].name, in: records) {
            case .matched(let metadata): candidates[index].metadata = metadata; candidates[index].name = metadata.name
            case .ambiguous: candidates[index].warnings.append("Ambiguous registration metadata. Choose XML before installing.")
            case .unresolved: candidates[index].warnings.append("Registration metadata unavailable. Import XML or use Extract Only.")
            }
            let artwork = try ArtworkService.discover(payloads: candidates[index].payloads, productName: candidates[index].name)
            candidates[index].artworkDiscovery = artwork
            candidates[index].artwork = artwork.selected?.url
            await ArtworkService.log(artwork, product: candidates[index].name, to: log)
            if candidates[index].artwork == nil { candidates[index].warnings.append("Artwork unavailable") }
            if FileManager.default.fileExists(atPath: candidates[index].destination.path) { candidates[index].state = .conflict }
            else if !candidates[index].warnings.isEmpty { candidates[index].state = .warning }
        }
        await log.log(.success, "Analysis complete: \(candidates.count) logical expansions from \(sources.count) sources")
        return AnalysisResult(session: session, candidates: candidates.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending })
    }
}
