import Foundation
import Darwin

private struct MountRecord: Codable { let id: UUID; let root: URL; let image: URL; let ownerPID: Int32? }
public struct MountRecovery: Sendable {
    public let log: LoggingService
    let runner: any ProcessRunning
    private var recordsRoot: URL { FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Maschine Machine/Mounts") }
    public init(log: LoggingService, runner: any ProcessRunning = ProcessRunner()) { self.log = log; self.runner = runner }
    func prepare(_ image: URL) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: recordsRoot, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try SafeTree.validate(recordsRoot)
        let id = UUID(), root = recordsRoot.appendingPathComponent(id.uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(MountRecord(id: id, root: root, image: image, ownerPID: getpid())).write(to: recordsRoot.appendingPathComponent(id.uuidString + ".json"), options: .atomic)
        return root
    }
    private func activeMounts() async throws -> [URL] {
        let result = try await runner.run("/usr/bin/hdiutil", ["info", "-plist"])
        guard result.code == 0 else { throw MachineError.process("hdiutil info", result.code, result.stderr) }
        let plist = try PropertyListSerialization.propertyList(from: result.stdout, format: nil) as? [String: Any]
        let images = plist?["images"] as? [[String: Any]] ?? []
        return images.flatMap { $0["system-entities"] as? [[String: Any]] ?? [] }.compactMap { ($0["mount-point"] as? String).map { URL(fileURLWithPath: $0) } }
    }
    func cleanup(_ root: URL) async throws {
        guard root.deletingLastPathComponent() == recordsRoot, UUID(uuidString: root.lastPathComponent) != nil else { throw MachineError.invalid("Invalid mount recovery root") }
        for mount in try await activeMounts() where mount.path.hasPrefix(root.path + "/") {
            let result = try await runner.run("/usr/bin/hdiutil", ["detach", mount.path])
            if result.code != 0 {
                guard !(try await activeMounts()).contains(mount) else { throw MachineError.process("hdiutil detach", result.code, result.stderr) }
            }
        }
        // Never remove a directory while any image is still mounted below it.
        guard !(try await activeMounts()).contains(where: { $0.path.hasPrefix(root.path + "/") }) else { throw MachineError.invalid("Mount cleanup is incomplete") }
        if FileManager.default.fileExists(atPath: root.path) { try FileManager.default.removeItem(at: root) }
        let record = recordsRoot.appendingPathComponent(root.lastPathComponent + ".json")
        if FileManager.default.fileExists(atPath: record.path) { try FileManager.default.removeItem(at: record) }
    }
    func cleanupAfterDetach(_ mount: URL) async throws {
        guard mount.path.hasPrefix(recordsRoot.path + "/") else { return }
        let root = recordsRoot.appendingPathComponent(mount.path.dropFirst(recordsRoot.path.count + 1).split(separator: "/").first.map(String.init) ?? "")
        try await cleanup(root)
    }
    public func recover() async throws {
        guard FileManager.default.fileExists(atPath: recordsRoot.path) else { return }
        for file in try SafeTree.children(recordsRoot) where file.pathExtension == "json" {
            let record = try JSONDecoder().decode(MountRecord.self, from: Data(contentsOf: file))
            if let owner = record.ownerPID, owner != getpid(), kill(owner, 0) == 0 || errno == EPERM { continue }
            try await cleanup(record.root); await log.log(.success, "Cleaned stale image workspace \(record.image.lastPathComponent)")
        }
    }
}
