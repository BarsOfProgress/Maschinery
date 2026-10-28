import Foundation
import CryptoKit

public struct InstallationPlan: Sendable {
    public let candidate: ExpansionCandidate
    public let mode: OperationMode
}
public enum InstallationPlanner {
    public static func plan(_ candidate: ExpansionCandidate, mode: OperationMode) throws -> InstallationPlan {
        let destination = candidate.destination.standardizedFileURL
        try SafeTree.validate(destination)
        guard destination.pathComponents.count > 2, !["/System", "/Library", "/usr", "/bin", "/sbin", "/private/etc", "/private/var/db", "/private/var/root"].contains(where: { destination.path == $0 || destination.path.hasPrefix($0 + "/") }) else { throw MachineError.invalid("Choose a user library destination, not a system directory") }
        guard !candidate.payloads.isEmpty else { throw MachineError.invalid("No library payloads") }
        for payload in candidate.payloads {
            let src = payload.standardizedFileURL.path
            guard destination.path != src, !destination.path.hasPrefix(src + "/"), !src.hasPrefix(destination.path + "/") else { throw MachineError.invalid("Source and destination overlap") }
        }
        if mode == .install { guard candidate.metadata != nil else { throw MachineError.invalid("Registration XML is required for Install") } }
        if FileManager.default.fileExists(atPath: destination.path), candidate.policy == .ask { throw MachineError.invalid("Existing destination: choose Merge, Replace or Skip") }
        return InstallationPlan(candidate: candidate, mode: mode)
    }
}
public struct CopyProgress: Sendable { public let bytes: Int64; public let total: Int64; public let phase: String }
public protocol PrivilegedService: Sendable {
    func register(_ metadata: RegistrationMetadata, content: URL) async throws
}
/// Deliberately fails closed until a signed, peer-authenticated helper is installed.
public struct UnavailablePrivilegedService: PrivilegedService {
    public init() {}
    public func register(_ metadata: RegistrationMetadata, content: URL) async throws { throw MachineError.unavailable("Registered installation requires the signed Maschine Machine helper. This development build supports Extract Only.") }
}
public struct InstallationService: Sendable {
    public let log: LoggingService
    public init(log: LoggingService) { self.log = log }
    public func execute(_ plan: InstallationPlan, progress: @Sendable (CopyProgress) async -> Void) async throws {
        // Preflight privileged support BEFORE copying or modifying any existing library.
        guard plan.mode == .extract else { throw MachineError.unavailable("Signed registration helper is not yet available. Select Extract Only; no files were changed.") }
        _ = try InstallationPlanner.plan(plan.candidate, mode: plan.mode)
        let c = plan.candidate
        if c.policy == .skip { return }
        let fm = FileManager.default, parent = c.destination.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        try SafeTree.validate(parent)
        let important = try parent.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage ?? 0
        let rawFree = (try fm.attributesOfFileSystem(forPath: parent.path)[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
        let capacity = important > 0 ? important : rawFree
        let existingBytes = c.policy == .merge && fm.fileExists(atPath: c.destination.path) ? try SafeTree.byteCount(c.destination) : 0
        guard capacity > c.size + existingBytes else { throw MachineError.invalid("Insufficient free space for staged installation") }
        let workspace = parent.appendingPathComponent(".maschine-\(UUID().uuidString)")
        try fm.createDirectory(at: workspace, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let staged = workspace.appendingPathComponent("content"), backup = workspace.appendingPathComponent("previous")
        var preserveRecovery = false
        defer { if !preserveRecovery { try? fm.removeItem(at: workspace) } }
        try fm.createDirectory(at: staged, withIntermediateDirectories: false)
        let exists = fm.fileExists(atPath: c.destination.path)
        if exists && c.policy == .merge {
            try SafeTree.walk(c.destination) { _ in true }; try fm.removeItem(at: staged); try fm.copyItem(at: c.destination, to: staged)
        }
        var copied: Int64 = 0
        for payload in c.payloads {
            try await copyTree(payload, to: staged) { bytes in
                copied += bytes
                await progress(CopyProgress(bytes: copied, total: c.size, phase: "Copying and verifying"))
            }
        }
        guard !(try SafeTree.children(staged)).isEmpty else { throw MachineError.invalid("Staged library is empty") }
        try Task.checkCancellation()
        // Commit is a short non-cancellable rename section on the destination volume.
        if exists { try fm.moveItem(at: c.destination, to: backup) }
        do { try fm.moveItem(at: staged, to: c.destination) }
        catch {
            if exists {
                do { try fm.moveItem(at: backup, to: c.destination) }
                catch {
                    preserveRecovery = true
                    await log.log(.error, "Rollback needs recovery. Original library preserved at \(backup.path): \(error.localizedDescription)")
                    throw MachineError.invalid("Commit and rollback failed. Original library preserved at \(backup.path). Do not delete this recovery directory.")
                }
            }; throw error
        }
        await log.log(.success, "Verified extraction committed: \(c.name)")
    }
    private func copyTree(_ source: URL, to destination: URL, bytes: (Int64) async -> Void) async throws {
        try Task.checkCancellation(); try SafeTree.validate(source); try SafeTree.validate(destination)
        let fm = FileManager.default
        if SafeTree.isDirectory(source) {
            if fm.fileExists(atPath: destination.path), !SafeTree.isDirectory(destination) { throw MachineError.invalid("File/directory conflict: \(destination.lastPathComponent)") }
            try fm.createDirectory(at: destination, withIntermediateDirectories: true)
            for child in try SafeTree.children(source) { try await copyTree(child, to: destination.appendingPathComponent(child.lastPathComponent), bytes: bytes) }
        } else {
            if SafeTree.isDirectory(destination) { throw MachineError.invalid("Directory/file conflict: \(destination.lastPathComponent)") }
            if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
            fm.createFile(atPath: destination.path, contents: nil)
            let input = try FileHandle(forReadingFrom: source), output = try FileHandle(forWritingTo: destination)
            defer { try? input.close(); try? output.close() }
            var original = SHA256()
            while let chunk = try input.read(upToCount: 1024 * 1024), !chunk.isEmpty {
                try Task.checkCancellation(); original.update(data: chunk); try output.write(contentsOf: chunk); await bytes(Int64(chunk.count))
            }
            try output.synchronize()
            let check = try FileHandle(forReadingFrom: destination); defer { try? check.close() }
            var copied = SHA256()
            while let chunk = try check.read(upToCount: 1024 * 1024), !chunk.isEmpty { try Task.checkCancellation(); copied.update(data: chunk) }
            guard original.finalize() == copied.finalize() else { throw MachineError.invalid("Verification failed: \(source.lastPathComponent)") }
        }
    }
}
