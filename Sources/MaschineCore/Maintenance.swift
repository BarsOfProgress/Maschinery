import Foundation
import Darwin

public struct RepairPlan: Sendable {
    public let request: RegistrationRequest
    public let changes: [String]
    public let content: URL
    public let permissionPaths: [URL]
}
public struct RepairService: Sendable {
    public let privileged: any PrivilegedService
    public let log: LoggingService
    public init(privileged: any PrivilegedService = XPCPrivilegedService(), log: LoggingService) { self.privileged = privileged; self.log = log }
    public func plan(_ library: InstalledLibrary, content: URL? = nil, explicit: [RegistrationMetadata] = [], hints: ProductHintsService, offline: Bool) async throws -> RepairPlan {
        guard let path = content ?? library.content, SafeTree.isDirectory(path) else { throw MachineError.invalid("Locate the existing library folder before repairing its registration") }
        try RegistrationValidation.content(path.path); try SafeTree.validate(path)
        let sharedRepair = path.deletingLastPathComponent().path == "/Users/Shared" && path.path == library.content?.path && ProductName.key(path.lastPathComponent) == ProductName.key(library.name)
        guard sharedRepair || LibraryRootDetector.isRoot(path) || SafeTree.isDirectory(path.appendingPathComponent("Samples")) || SafeTree.isDirectory(path.appendingPathComponent("Sounds")) else { throw MachineError.invalid("Selected directory does not look like a Maschine library") }
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
        case .ambiguous: throw MachineError.invalid("Multiple metadata records match. Choose one product XML explicitly.")
        case .unresolved:
            guard !offline else { throw MachineError.invalid("Offline: choose a matching XML before repairing this library") }
            let remote = try await hints.records(offline: false)
            guard case .matched(let match) = MetadataMatchingService.match(library.name, in: remote) else { throw MachineError.invalid("ProductHints did not resolve this library. Choose XML.") }; metadata = match
        }
        if metadata.version == nil { metadata.version = library.version }
        let request: RegistrationRequest
        if sharedRepair {
            request = RegistrationRequest(product: metadata.name, contentPath: path.path, version: metadata.version ?? "1.0.0", xml: metadata.xml, resources: [], repairSharedPermissions: true)
            try request.validate()
        } else { request = try RegistrationBuilder.build(metadata: metadata, content: path) }
        var permissionPaths: [URL] = []
        if !sharedRepair { try SafeTree.walk(path) { url in
            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            let mode = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0
            let required = SafeTree.isDirectory(url) ? 0o500 : 0o400
            if mode & required != required { permissionPaths.append(url) }; return true
        } }
        var changes = ["Set \(library.name) ContentDir to \(path.path)", "Install and verify product XML (\(metadata.source))", "Set selected product registration files to root-owned, readable 0644"]
        if sharedRepair { changes.append("Inspect the registered shared library without following links; add only missing read/traversal permissions and recover its product artwork. Original modes are journaled for rollback.") }
        if !request.resources.isEmpty { changes.append("Recover \(request.resources.count) product artwork/resource files from PAResources") }
        if !permissionPaths.isEmpty { changes.append("Add missing owner read (and directory traversal) on \(permissionPaths.count) selected-library paths owned by you") }
        return RepairPlan(request: request, changes: changes, content: path, permissionPaths: permissionPaths)
    }
    public func execute(_ plan: RepairPlan) async throws {
        try await privileged.preflight(); try Task.checkCancellation()
        // Never broaden permissions on another owner's files or traverse symbolic links.
        for path in plan.permissionPaths {
            try SafeTree.validate(path)
            let attrs = try FileManager.default.attributesOfItem(atPath: path.path)
            guard (attrs[.ownerAccountID] as? NSNumber)?.uint32Value == getuid() else { throw MachineError.invalid("Cannot repair another owner’s library permissions without broad privilege. Choose a readable copy: \(path.path)") }
        }
        var undo: [(SecureDirectory, String, mode_t, ino_t)] = []
        var finished = false
        defer {
            for (parent, name, mode, inode) in undo where !finished {
                var info = stat()
                if fstatat(parent.fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0 && info.st_ino == inode { _ = fchmodat(parent.fd, name, mode, AT_SYMLINK_NOFOLLOW) }
            }
        }
        for path in plan.permissionPaths {
            try SafeTree.validate(path)
            let parent = try SecureDirectory(root: path.deletingLastPathComponent(), create: false)
            let name = path.lastPathComponent
            var info = stat()
            guard fstatat(parent.fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFDIR || info.st_mode & S_IFMT == S_IFREG && info.st_nlink == 1 else { throw MachineError.invalid("Permission target changed") }
            undo.append((parent, name, info.st_mode, info.st_ino))
            let needed: mode_t = info.st_mode & S_IFMT == S_IFDIR ? 0o500 : 0o400
            guard fchmodat(parent.fd, name, info.st_mode | needed, AT_SYMLINK_NOFOLLOW) == 0 else { throw SecureDirectory.failure("repair owner read permissions") }
        }
        try await registrationTransaction(plan.request)
        finished = true
        await log.log(.success, "Repaired and verified \(plan.request.product)")
    }
    private func registrationTransaction(_ request: RegistrationRequest) async throws {
        // Retain a user-side receipt until helper commit; launch recovery rolls back uncertain repairs.
        let root = TransactionStore().root.appendingPathComponent("Repairs")
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
        let root = TransactionStore().root.appendingPathComponent("Repairs")
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
        guard !FileManager.default.fileExists(atPath: destination.path) else { throw MachineError.invalid("Relocation destination already exists; choose an empty location") }
        let metadata = RegistrationMetadata(name: plan.request.product, version: plan.request.version, xml: plan.request.xml, source: .user)
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
        guard let fingerprint = artifact.fingerprint, try SourceIdentity.capture(artifact.url) == fingerprint else { throw MachineError.invalid("Source changed since analysis. It has been preserved: " + artifact.url.lastPathComponent) }
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
