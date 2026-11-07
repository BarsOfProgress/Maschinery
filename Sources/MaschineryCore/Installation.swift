import Foundation
import CryptoKit
import Darwin

public struct InstallationPlan: Sendable {
    public let candidate: ExpansionCandidate
    public let mode: OperationMode
}
public enum InstallationPlanner {
    public static func plan(_ candidate: ExpansionCandidate, mode: OperationMode) throws -> InstallationPlan {
        let destination = candidate.destination.standardizedFileURL
        try RegistrationValidation.content(destination.path)
        try SafeTree.validate(destination)
        guard destination.pathComponents.count > 2, !["/System", "/Library", "/usr", "/bin", "/sbin", "/private/etc", "/private/var/db", "/private/var/root"].contains(where: { destination.path == $0 || destination.path.hasPrefix($0 + "/") }) else { throw MaschineryError.invalid("Choose a user library destination, not a system directory") }
        guard !candidate.payloads.isEmpty else { throw MaschineryError.invalid("No library payloads") }
        for payload in candidate.payloads {
            let src = payload.standardizedFileURL.path
            guard destination.path != src, !destination.path.hasPrefix(src + "/"), !src.hasPrefix(destination.path + "/") else { throw MaschineryError.invalid("Source and destination overlap") }
        }
        if mode == .install { guard candidate.metadata != nil else { throw MaschineryError.invalid("Registration XML is required for Install") } }
        if (FileManager.default.fileExists(atPath: destination.path) || candidate.existingPath != nil), candidate.policy == .ask { throw MaschineryError.invalid("Existing destination: choose Merge, Replace or Skip") }
        return InstallationPlan(candidate: candidate, mode: mode)
    }
}
public struct CopyProgress: Sendable { public let bytes: Int64; public let total: Int64; public let phase: String }
public struct InstallationService: Sendable {
    public let log: LoggingService
    public let privileged: any PrivilegedService
    public let transactions: TransactionStore
    public init(log: LoggingService, privileged: any PrivilegedService = XPCPrivilegedService(), transactions: TransactionStore = TransactionStore()) { self.log = log; self.privileged = privileged; self.transactions = transactions }
    public func execute(_ plan: InstallationPlan, progress: @Sendable (CopyProgress) async -> Void) async throws {
        let c = plan.candidate
        if c.policy == .skip { return }
        _ = try InstallationPlanner.plan(c, mode: plan.mode)
        if plan.mode == .install { try await privileged.preflight() }
        try Task.checkCancellation()
        let fm = FileManager.default, parent = c.destination.deletingLastPathComponent()
        try SafeTree.validate(parent)
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        let important = try parent.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage ?? 0
        let rawFree = (try fm.attributesOfFileSystem(forPath: parent.path)[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
        let capacity = important > 0 ? important : rawFree
        let exists = fm.fileExists(atPath: c.destination.path)
        let actualBytes = try c.payloads.reduce(Int64(0)) { try $0 + SafeTree.byteCount($1) }
        let existingBytes = c.policy == .merge && exists ? try SafeTree.byteCount(c.destination) : 0
        guard capacity > actualBytes + existingBytes else { throw MaschineryError.invalid("Insufficient disk space including staging and existing merged content") }
        let id = UUID(), workspace = parent.appendingPathComponent(".maschinery-\(id.uuidString)")
        let staged = workspace.appendingPathComponent("content"), backup = workspace.appendingPathComponent("previous")
        try fm.createDirectory(at: workspace, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        var journal = ContentJournal(id: id, destination: c.destination, workspace: workspace, hadDestination: exists, registered: plan.mode == .install, phase: .staging)
        if plan.mode == .install && exists && parent.path == "/Users/Shared",
           (try fm.attributesOfItem(atPath: c.destination.path)[.ownerAccountID] as? NSNumber)?.uint32Value != getuid() {
            journal.privilegedContent = SharedContentRequest(transaction: id, product: c.metadata?.name ?? c.name, destination: c.destination.path)
        }
        try transactions.save(journal)
        var registration: RegistrationRequest?
        var committed = false
        do {
            try fm.createDirectory(at: staged, withIntermediateDirectories: false)
            var copied: Int64 = 0
            if exists && c.policy == .merge {
                try await copyTree(c.destination, to: staged) { bytes in
                    copied += bytes; await progress(CopyProgress(bytes: copied, total: actualBytes + existingBytes, phase: "Preserving existing files"))
                }
            }
            for payload in c.payloads {
                try await copyTree(payload, to: staged) { bytes in
                    copied += bytes; await progress(CopyProgress(bytes: copied, total: actualBytes + existingBytes, phase: "Copying and verifying payload"))
                }
            }
            guard !(try SafeTree.children(staged)).isEmpty else { throw MaschineryError.invalid("Staged library is empty") }
            if plan.mode == .install, let metadata = c.metadata {
                registration = try RegistrationBuilder.build(metadata: metadata, content: c.destination, transaction: id, resourcesRoot: staged.appendingPathComponent("PAResources/image"))
                if metadata.version == nil { await log.log(.warning, "\(c.name): metadata has no ContentVersion; using documented 1.0.0 fallback") }
            }
            try Task.checkCancellation()
            journal.phase = .swapping; try transactions.save(journal)
            if let shared = journal.privilegedContent { try await privileged.swapShared(shared) }
            else {
                if exists { try fm.moveItem(at: c.destination, to: backup) }
                try fm.moveItem(at: staged, to: c.destination)
            }
            journal.phase = .contentReady; try transactions.save(journal)
            if let registration {
                await progress(CopyProgress(bytes: copied, total: actualBytes + existingBytes, phase: "Installing NI registration and artwork"))
                try await privileged.apply(registration)
                try Task.checkCancellation()
                try await privileged.verify(registration)
            }
            guard SafeTree.isDirectory(c.destination), !(try SafeTree.children(c.destination)).isEmpty else { throw MaschineryError.invalid("Final content verification failed") }
            try Task.checkCancellation()
            // Once finish is acknowledged, cancellation cannot turn this verified commit into a failure.
            if let registration { try await privileged.finish(registration.transaction) }
            committed = true
            journal.phase = .committed; try transactions.save(journal)
            if let shared = journal.privilegedContent { try await privileged.cleanupShared(shared) }
            try fm.removeItem(at: workspace); try transactions.remove(id)
            await log.log(.success, "Verified \(plan.mode.rawValue): \(c.name)")
        } catch {
            // A lost finish reply is ambiguous. Query durable state before deciding whether to undo content.
            if registration != nil && !committed {
                do { committed = try await Task.detached { try await privileged.phase(id) == .committed }.value }
                catch { await log.log(.error, "Recovery required for \(c.name), transaction \(id): \(error.localizedDescription)"); throw MaschineryError.invalid("Connection lost; recovery journal retained. Do not remove \(workspace.path)") }
            }
            if committed {
                await log.log(.warning, "\(c.name) is verified and committed; temporary cleanup will retry at next launch")
                return
            }
            do {
                if registration != nil { try await Task.detached { try await privileged.rollback(id) }.value }
                if let shared = journal.privilegedContent { try await Task.detached { try await privileged.restoreShared(shared) }.value }
                if fm.fileExists(atPath: backup.path) {
                    if fm.fileExists(atPath: c.destination.path) { try fm.removeItem(at: c.destination) }
                    try fm.moveItem(at: backup, to: c.destination)
                } else if !exists && journal.phase != .staging && !fm.fileExists(atPath: staged.path) && fm.fileExists(atPath: c.destination.path) { try fm.removeItem(at: c.destination) }
                try fm.removeItem(at: workspace); try transactions.remove(id)
                await log.log(.warning, "Rolled back \(c.name)")
            } catch { await log.log(.error, "Rollback requires recovery: \(workspace.path) — \(error.localizedDescription)"); throw MaschineryError.invalid("Rollback incomplete. Recovery data preserved at \(workspace.path)") }
            throw error
        }
    }
    func copyTree(_ source: URL, to destination: URL, bytes: (Int64) async -> Void) async throws {
        try Task.checkCancellation(); try SafeTree.validate(source); try SafeTree.validate(destination)
        if SafeTree.isDirectory(source) {
            _ = try SecureDirectory(root: source, create: false)
            _ = try SecureDirectory(root: destination)
            for child in try SafeTree.children(source, includeHidden: true) { try await copyTree(child, to: destination.appendingPathComponent(child.lastPathComponent), bytes: bytes) }
        } else {
            let sourceParent = try SecureDirectory(root: source.deletingLastPathComponent(), create: false)
            let destinationParent = try SecureDirectory(root: destination.deletingLastPathComponent())
            let inputFD = openat(sourceParent.fd, source.lastPathComponent, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard inputFD >= 0 else { throw SecureDirectory.failure("open payload without links") }
            let input = FileHandle(fileDescriptor: inputFD, closeOnDealloc: true)
            var sourceInfo = stat()
            guard fstat(inputFD, &sourceInfo) == 0, sourceInfo.st_mode & S_IFMT == S_IFREG else { throw MaschineryError.invalid("Payload is not a regular file: " + source.lastPathComponent) }
            var targetInfo = stat()
            if fstatat(destinationParent.fd, destination.lastPathComponent, &targetInfo, AT_SYMLINK_NOFOLLOW) == 0 {
                guard targetInfo.st_mode & S_IFMT == S_IFREG else { throw MaschineryError.invalid("Unexpected destination conflict: " + destination.lastPathComponent) }
                guard unlinkat(destinationParent.fd, destination.lastPathComponent, 0) == 0 else { throw SecureDirectory.failure("replace staged payload") }
            } else if errno != ENOENT { throw SecureDirectory.failure("inspect staged payload") }
            let outputFD = openat(destinationParent.fd, destination.lastPathComponent, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o644))
            guard outputFD >= 0 else { throw SecureDirectory.failure("create staged payload") }
            let output = FileHandle(fileDescriptor: outputFD, closeOnDealloc: true)
            var original = SHA256()
            while let chunk = try input.read(upToCount: 1024 * 1024), !chunk.isEmpty {
                try Task.checkCancellation(); original.update(data: chunk); try output.write(contentsOf: chunk); await bytes(Int64(chunk.count))
            }
            var finalSource = stat()
            guard fstat(inputFD, &finalSource) == 0, finalSource.st_size == sourceInfo.st_size, finalSource.st_mtimespec.tv_sec == sourceInfo.st_mtimespec.tv_sec, finalSource.st_mtimespec.tv_nsec == sourceInfo.st_mtimespec.tv_nsec else { throw MaschineryError.invalid("Source changed while copying: " + source.lastPathComponent) }
            try output.synchronize(); try output.seek(toOffset: 0)
            var copied = SHA256()
            while let chunk = try output.read(upToCount: 1024 * 1024), !chunk.isEmpty { try Task.checkCancellation(); copied.update(data: chunk) }
            guard original.finalize() == copied.finalize() else { throw MaschineryError.invalid("Verification failed: " + source.lastPathComponent) }
            try input.close(); try output.close()
        }
    }
}
