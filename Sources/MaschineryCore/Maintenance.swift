import Foundation
import Darwin

public struct RepairPlan: Sendable {
    public let request: RegistrationRequest?
    public var permissions: PermissionRepairRequest? = nil
    public var product: String { request?.product ?? permissions?.product ?? content.lastPathComponent }
    public let changes: [String]
    public let content: URL
    public let permissionPaths: [URL]
}
public struct RepairService: Sendable {
    public let privileged: any PrivilegedService
    public let log: LoggingService
    public let transactionRoot: URL
    public init(privileged: any PrivilegedService = XPCPrivilegedService(), log: LoggingService, transactionRoot: URL = TransactionStore().root) { self.privileged = privileged; self.log = log; self.transactionRoot = transactionRoot }
    public func permissionPlan(_ library: InstalledLibrary) throws -> RepairPlan {
        guard let content = library.content else { throw MaschineryError.invalid("This library has no verified content location. Locate its existing expansion folder before permission repair.") }
        let request = try PermissionRepairRequest.capture(product: library.name, content: content)
        return RepairPlan(request: nil, permissions: request, changes: [
            "Verify native Groups/Sounds content and product identity inside " + request.contentPath,
            "Reject links, nested filesystems, changed file identities and content owned by another user",
            "Add only missing read/traversal bits for your existing permission class; preserve ownership, write bits and existing file execution bits",
            "Journal original modes before changes and verify the complete expansion afterward",
            "Leave NI registration preferences, Service Center XML, databases and resource directories unchanged. Missing artwork or registration issues require their separate actions."
        ], content: URL(fileURLWithPath: request.contentPath), permissionPaths: [])
    }
    public func plan(_ library: InstalledLibrary, content: URL? = nil, explicit: [RegistrationMetadata] = [], hints: ProductHintsService, offline: Bool) async throws -> RepairPlan {
        guard let path = content ?? library.content, SafeTree.isDirectory(path) else { throw MaschineryError.invalid("Locate the existing library folder before repairing its registration") }
        try RegistrationValidation.content(path.path); try SafeTree.validate(path)
        let sharedRepair = path.deletingLastPathComponent().path == "/Users/Shared" && path.path == library.content?.path && ProductName.key(path.lastPathComponent) == ProductName.key(library.name)
        guard sharedRepair || LibraryRootDetector.isRoot(path) || SafeTree.isDirectory(path.appendingPathComponent("Samples")) || SafeTree.isDirectory(path.appendingPathComponent("Sounds")) else { throw MaschineryError.invalid("Selected directory does not look like a Maschine library") }
        var records = explicit
        let xmlPath = library.serviceCenter.appendingPathComponent(library.name + ".xml")
        if FileManager.default.isReadableFile(atPath: xmlPath.path) { records += try MetadataXML.read(xmlPath, source: .embedded) }
        do {
            try SafeTree.walk(path) { url in
                if url.pathExtension.lowercased() == "xml", url.path.lowercased().contains("service cent") { records += try MetadataXML.read(url, source: .embedded) }; return true
            }
        } catch { if !sharedRepair { throw error }; await log.log(.warning, "Shared library read permissions will be inspected by the helper: " + error.localizedDescription) }
        var metadata: RegistrationMetadata
        switch MetadataMatchingService.match(library.name, in: records) {
        case .matched(let match): metadata = match
        case .ambiguous: throw MaschineryError.invalid("Multiple metadata records match. Choose one product XML explicitly.")
        case .unresolved:
            guard !offline else { throw MaschineryError.invalid("Offline: choose a matching XML before repairing this library") }
            let remote = try await hints.records(offline: false)
            guard case .matched(let match) = MetadataMatchingService.match(library.name, in: remote) else { throw MaschineryError.invalid("ProductHints did not resolve this library. Choose XML.") }; metadata = match
        }
        if metadata.version == nil { metadata.version = library.version }
        // Explicit Locate Content / Replace XML / Relocate reviews may update
        // registration, but never silently include recursive permission repair.
        let request = try RegistrationBuilder.build(metadata: metadata, content: path)
        var changes = ["Set \(library.name) ContentDir to \(path.path)", "Install and verify product XML (\(metadata.source))", "Set selected product registration files to root-owned, readable 0644"]
        if !request.resources.isEmpty { changes.append("Recover \(request.resources.count) product artwork/resource files from PAResources") }
        return RepairPlan(request: request, changes: changes, content: path, permissionPaths: [])
    }
    public func execute(_ plan: RepairPlan) async throws {
        if let permissions = plan.permissions {
            guard plan.request == nil else { throw MaschineryError.invalid("Permission repair cannot include registration changes") }
            try await permissionTransaction(permissions)
            await log.log(.success, "Verified expansion permissions for " + permissions.product + "; NI registrations unchanged")
            return
        }
        guard let request = plan.request else { throw MaschineryError.invalid("Maintenance plan is empty") }
        try await privileged.preflight(); try Task.checkCancellation()
        try await registrationTransaction(request)
        await log.log(.success, "Repaired and verified \(request.product) registration")
    }
    private func permissionTransaction(_ request: PermissionRepairRequest) async throws {
        try await privileged.preflight(); try Task.checkCancellation()
        let root = transactionRoot.appendingPathComponent("PermissionRepairs")
        try SafeTree.validate(root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = root.appendingPathComponent(request.transaction.uuidString + ".json")
        try JSONEncoder().encode(request).write(to: file, options: .atomic)
        do {
            try await privileged.repairPermissions(request); try Task.checkCancellation()
            try await privileged.verifyPermissions(request); try Task.checkCancellation()
            try await privileged.finish(request.transaction)
        } catch {
            let service = privileged
            let committed = try await Task.detached { try await service.phase(request.transaction) == .committed }.value
            if !committed {
                try await Task.detached { try await service.rollback(request.transaction) }.value
                try FileManager.default.removeItem(at: file)
                throw error
            }
        }
        do { try FileManager.default.removeItem(at: file) }
        catch { await log.log(.warning, "Permission repair is committed; receipt cleanup will retry at launch: " + error.localizedDescription) }
    }
    public func uninstall(_ library: InstalledLibrary, trashContent: Bool) async throws {
        guard let content = library.content else { throw MaschineryError.invalid("Uninstall requires a valid registered content path") }
        let request = RegistrationRequest(product: library.name, contentPath: content.path, version: library.version ?? "1.0.0", xml: Data(), resources: [], uninstall: true)
        try request.validate()
        // Capture before registration changes; refuse to trash shared or changed content.
        let source = trashContent && FileManager.default.fileExists(atPath: content.path) ? SourceArtifact(url: content, type: .folder) : nil
        if trashContent {
            let registrations = try ExistingLibraryService.audit(preferences: library.id.deletingLastPathComponent(), serviceCenter: library.serviceCenter)
            guard !registrations.contains(where: { other in
                guard other.id != library.id, let path = other.content?.standardizedFileURL.path else { return false }
                let selected = content.standardizedFileURL.path
                return path == selected || path.hasPrefix(selected + "/") || selected.hasPrefix(path + "/")
            }) else { throw MaschineryError.invalid("Another registered product shares this content. Uninstall with Keep Files instead.") }
            if let source, source.fingerprint == nil { throw MaschineryError.invalid("Cannot verify content identity. Uninstall with Keep Files instead.") }
        }
        try await privileged.preflight(); try Task.checkCancellation()
        try await registrationTransaction(request)
        await log.log(.success, "Uninstalled registration for " + library.name + "; cached artwork retained")
        if let source {
            do { try SourceTrashService.trash(source) }
            catch {
                await log.log(.warning, "Registration removed; content retained at " + content.path + ": " + error.localizedDescription)
                throw MaschineryError.invalid("Registration removed, but content could not be moved to Trash. Files remain at " + content.path + ": " + error.localizedDescription)
            }
        }
    }
    private func registrationTransaction(_ request: RegistrationRequest) async throws {
        // Retain a user-side receipt until helper commit; launch recovery rolls back uncertain repairs.
        let root = transactionRoot.appendingPathComponent("Repairs")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = root.appendingPathComponent(request.transaction.uuidString + ".json")
        try JSONEncoder().encode(request).write(to: file, options: .atomic)
        do {
            try await privileged.apply(request); try Task.checkCancellation(); try await privileged.verify(request); try Task.checkCancellation(); try await privileged.finish(request.transaction)
        } catch {
            let service = privileged
            let committed = try await Task.detached { try await service.phase(request.transaction) == .committed }.value
            if !committed { try await Task.detached { try await service.rollback(request.transaction) }.value; try FileManager.default.removeItem(at: file); throw error }
        }
        do { try FileManager.default.removeItem(at: file) }
        catch { await log.log(.warning, "Repair is committed; receipt cleanup will retry at launch: " + error.localizedDescription) }
    }
    public func recover() async throws {
        let permissionsRoot = transactionRoot.appendingPathComponent("PermissionRepairs")
        if FileManager.default.fileExists(atPath: permissionsRoot.path) {
            for file in try SafeTree.children(permissionsRoot) where file.pathExtension == "json" {
                let request = try JSONDecoder().decode(PermissionRepairRequest.self, from: Data(contentsOf: file))
                if try await privileged.phase(request.transaction) != .committed { try await privileged.rollback(request.transaction) }
                try FileManager.default.removeItem(at: file)
            }
        }
        let root = transactionRoot.appendingPathComponent("Repairs")
        guard FileManager.default.fileExists(atPath: root.path) else { return }
        for file in try SafeTree.children(root) where file.pathExtension == "json" {
            let request = try JSONDecoder().decode(RegistrationRequest.self, from: Data(contentsOf: file))
            if try await privileged.phase(request.transaction) != .committed { try await privileged.rollback(request.transaction) }
            try FileManager.default.removeItem(at: file)
        }
    }
}
public struct RelocationService: Sendable {
    public let privileged: any PrivilegedService
    public let log: LoggingService
    public init(privileged: any PrivilegedService = XPCPrivilegedService(), log: LoggingService) { self.privileged = privileged; self.log = log }
    public func relocate(_ plan: RepairPlan, destination: URL, trashOld: Bool, progress: @Sendable (CopyProgress) async -> Void) async throws {
        guard !FileManager.default.fileExists(atPath: destination.path) else { throw MaschineryError.invalid("Relocation destination already exists; choose an empty location") }
        guard let request = plan.request, plan.permissions == nil else { throw MaschineryError.invalid("Relocation requires its explicit registration review") }
        let metadata = RegistrationMetadata(name: request.product, version: request.version, xml: request.xml, source: .user)
        let source = SourceArtifact(url: plan.content, type: .folder)
        let candidate = ExpansionCandidate(name: metadata.name, sources: [source], payloads: [plan.content], destination: destination, size: try SafeTree.byteCount(plan.content), metadata: metadata)
        try await InstallationService(log: log, privileged: privileged).execute(InstallationPlanner.plan(candidate, mode: .install), progress: progress)
        if trashOld && !Task.isCancelled {
            do {
                try SourceTrashService.trash(source)
                await log.log(.success, "Moved verified relocation’s old content to Trash")
            } catch { await log.log(.warning, "Relocation is verified; old content was preserved: " + error.localizedDescription) }
        }
    }
}
public enum SourceTrashService {
    @discardableResult public static func trash(_ artifact: SourceArtifact) throws -> URL? {
        guard let fingerprint = artifact.fingerprint, try SourceIdentity.capture(artifact.url) == fingerprint else { throw MaschineryError.invalid("Source changed since analysis. It has been preserved: " + artifact.url.lastPathComponent) }
        return try trash(artifact.url)
    }
    @discardableResult public static func trash(_ source: URL) throws -> URL? {
        try SafeTree.validate(source)
        try RegistrationValidation.content(source.path)
        // Native Trash is reversible; never fall back to unlink/removeItem.
        var resulting: NSURL?
        try FileManager.default.trashItem(at: source, resultingItemURL: &resulting)
        return resulting as URL?
    }
    public static func eligibleSources(candidates: [ExpansionCandidate], selected: Set<UUID>) -> [SourceArtifact] {
        var sources: [String: SourceArtifact] = [:]
        for candidate in candidates where selected.contains(candidate.id) { for source in candidate.sources { sources[source.url.standardizedFileURL.path] = source } }
        return sources.values.filter { source in
            let dependencies = candidates.filter { $0.sources.contains { $0.url.standardizedFileURL == source.url.standardizedFileURL } }
            return !dependencies.isEmpty && dependencies.allSatisfy { selected.contains($0.id) && $0.state == .installed }
        }.sorted { $0.url.path < $1.url.path }
    }
}
