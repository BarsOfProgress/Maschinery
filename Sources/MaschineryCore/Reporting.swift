import Foundation
public struct BatchReport: Codable, Sendable {
    public struct Item: Codable, Sendable {
        public let name: String, destination: String, state: CandidateState
        public let sources: [String], warnings: [String]
    }
    public let date: Date
    public let appVersion: String
    public let mode: OperationMode
    public let items: [Item]
    public var cleanup: [String]
    public init(candidates: [ExpansionCandidate], mode: OperationMode, cleanup: [String] = []) {
        date = Date(); appVersion = "1.0.5"; self.mode = mode; self.cleanup = cleanup
        items = candidates.map { Item(name: $0.name, destination: $0.destination.path, state: $0.state, sources: $0.sources.map { $0.url.lastPathComponent }, warnings: $0.warnings) }
    }
}
