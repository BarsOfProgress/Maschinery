import Foundation

public enum SourceType: String, Codable, Sendable { case folder, pkg, iso }
public struct SourceArtifact: Identifiable, Hashable, Codable, Sendable {
    public let id: UUID
    public let url: URL
    public let type: SourceType
    public init(url: URL, type: SourceType) { id = UUID(); self.url = url; self.type = type }
}
public enum MetadataSource: Int, Codable, Sendable { case productHints = 0, embedded = 1, user = 2 }
public struct RegistrationMetadata: Hashable, Sendable {
    public var name: String
    public var version: String?
    public var xml: Data
    public var source: MetadataSource
    public init(name: String, version: String? = nil, xml: Data, source: MetadataSource) { self.name = name; self.version = version; self.xml = xml; self.source = source }
}
public enum CandidateState: String, Codable, Sendable { case ready, warning, conflict, installing, installed, failed, cancelled, skipped }
public enum ConflictPolicy: String, CaseIterable, Codable, Sendable { case ask, merge, replace, skip }
public enum OperationMode: String, CaseIterable, Codable, Sendable { case install = "Install", extract = "Extract Only" }
public struct ExpansionCandidate: Identifiable, Sendable {
    public let id: UUID
    public var name: String
    public var sources: [SourceArtifact]
    public var payloads: [URL]
    public var destination: URL
    public var size: Int64
    public var artwork: URL?
    public var metadata: RegistrationMetadata?
    public var warnings: [String]
    public var state: CandidateState
    public var policy: ConflictPolicy = .ask
    public init(name: String, sources: [SourceArtifact], payloads: [URL], destination: URL, size: Int64 = 0, artwork: URL? = nil, metadata: RegistrationMetadata? = nil, warnings: [String] = [], state: CandidateState = .ready) {
        id = UUID(); self.name = name; self.sources = sources; self.payloads = payloads; self.destination = destination; self.size = size; self.artwork = artwork; self.metadata = metadata; self.warnings = warnings; self.state = state
    }
}
public enum MachineError: LocalizedError {
    case invalid(String), process(String, Int32, String), unavailable(String)
    public var errorDescription: String? { switch self { case .invalid(let s), .unavailable(let s): s; case .process(let tool, let code, let detail): "\(tool) exited \(code): \(detail)" } }
}
public enum LogLevel: String, Codable, CaseIterable, Sendable { case debug, info, warning, error, success }
public struct LogEntry: Identifiable, Codable, Sendable {
    public let id: UUID; public let date: Date; public let level: LogLevel; public let message: String
    public init(_ level: LogLevel, _ message: String) { id = UUID(); date = Date(); self.level = level; self.message = message }
}
public actor LoggingService {
    private var entries: [LogEntry] = []
    public init() {}
    public func log(_ level: LogLevel, _ message: String) { entries.append(LogEntry(level, message)) }
    public func snapshot() -> [LogEntry] { entries }
}
public enum SourceCleanup {
    public static func eligible(source: UUID, candidates: [ExpansionCandidate]) -> Bool {
        let dependents = candidates.filter { $0.sources.contains { $0.id == source } }
        return !dependents.isEmpty && dependents.allSatisfy { $0.state == .installed }
    }
}
