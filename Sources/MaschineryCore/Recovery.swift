import Foundation

public struct ContentJournal: Codable, Sendable {
    public enum Phase: String, Codable, Sendable { case staging, swapping, contentReady, committed }
    public let id: UUID, destination: URL, workspace: URL
    public let hadDestination: Bool, registered: Bool
    public var phase: Phase
    public var privilegedContent: SharedContentRequest? = nil
}
public struct TransactionStore: Sendable {
    public let root: URL
    public init(root: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Maschinery/Transactions")) { self.root = root }
    public func save(_ record: ContentJournal) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try SafeTree.validate(root)
        try JSONEncoder().encode(record).write(to: root.appendingPathComponent(record.id.uuidString + ".json"), options: .atomic)
    }
    public func remove(_ id: UUID) throws { try FileManager.default.removeItem(at: root.appendingPathComponent(id.uuidString + ".json")) }
    public func records() throws -> [ContentJournal] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        return try SafeTree.children(root).filter { $0.pathExtension == "json" }.map { try JSONDecoder().decode(ContentJournal.self, from: Data(contentsOf: $0)) }
    }
    public func recover(using privileged: any PrivilegedService, log: LoggingService) async throws {
        for record in try records() {
            try RegistrationValidation.content(record.destination.path)
            guard record.workspace.deletingLastPathComponent() == record.destination.deletingLastPathComponent(), record.workspace.lastPathComponent == ".maschinery-" + record.id.uuidString else { throw MaschineryError.invalid("Invalid recovery journal paths") }
            try SafeTree.validate(record.workspace); try SafeTree.validate(record.destination)
            let committed: Bool
            if record.registered {
                let phase = try await privileged.phase(record.id)
                committed = phase == .committed
                if !committed { try await privileged.rollback(record.id) }
            } else { committed = record.phase == .committed }
            let fm = FileManager.default, backup = record.workspace.appendingPathComponent("previous"), staged = record.workspace.appendingPathComponent("content")
            if let shared = record.privilegedContent {
                if committed { try await privileged.cleanupShared(shared) }
                else { try await privileged.restoreShared(shared) }
            }
            if !committed {
                if fm.fileExists(atPath: backup.path) {
                    if fm.fileExists(atPath: record.destination.path) { try fm.removeItem(at: record.destination) }
                    try fm.moveItem(at: backup, to: record.destination)
                } else if !record.hadDestination && record.phase != .staging && !fm.fileExists(atPath: staged.path) && fm.fileExists(atPath: record.destination.path) { try fm.removeItem(at: record.destination) }
            }
            if fm.fileExists(atPath: record.workspace.path) { try fm.removeItem(at: record.workspace) }
            try remove(record.id)
            await log.log(.success, committed ? "Recovered completed transaction \(record.id)" : "Rolled back interrupted transaction \(record.id)")
        }
    }
}
