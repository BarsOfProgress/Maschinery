import Foundation

public struct ResourceFile: Codable, Sendable, Hashable {
    public let path: String
    public let data: Data
    public init(path: String, data: Data) { self.path = path; self.data = data }
}
public struct RegistrationRequest: Codable, Sendable {
    public let transaction: UUID
    public let product: String
    public let contentPath: String
    public let version: String
    public let xml: Data
    public let resources: [ResourceFile]
    public let repairSharedPermissions: Bool
    public init(transaction: UUID = UUID(), product: String, contentPath: String, version: String, xml: Data, resources: [ResourceFile], repairSharedPermissions: Bool = false) {
        self.transaction = transaction; self.product = product; self.contentPath = contentPath; self.version = version; self.xml = xml; self.resources = resources; self.repairSharedPermissions = repairSharedPermissions
    }
    public func validate() throws {
        try RegistrationValidation.product(product)
        try RegistrationValidation.content(contentPath)
        guard !version.isEmpty, version.count < 128, xml.count <= 8 * 1024 * 1024, resources.count <= 2048,
              resources.reduce(xml.count, { $0 + $1.data.count }) <= 48 * 1024 * 1024 else { throw MachineError.invalid("Registration request exceeds safety limits") }
        let records = try MetadataXML.parse(xml, source: .user)
        guard records.count == 1, records[0].name == product else { throw MachineError.invalid("XML must contain exactly the selected product name") }
        var seen = Set<String>()
        for resource in resources {
            try RegistrationValidation.relative(resource.path)
            guard seen.insert(resource.path.lowercased()).inserted, resource.data.count <= 16 * 1024 * 1024 else { throw MachineError.invalid("Duplicate or oversized NI resource") }
        }
    }
}
public enum RegistrationValidation {
    public static func product(_ name: String) throws {
        guard !name.isEmpty, name.utf8.count <= 180, name != ".", name != "..", name == name.trimmingCharacters(in: .whitespacesAndNewlines), !name.contains("/"), !name.contains(":"), !name.contains("\\"), !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw MachineError.invalid("Unsafe product name") }
    }
    public static func relative(_ value: String) throws {
        guard !value.isEmpty, value.utf8.count < 1024, !value.hasPrefix("/"), !value.contains("\\"), value.split(separator: "/", omittingEmptySubsequences: false).allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains(":") && !$0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) }) else { throw MachineError.invalid("Unsafe relative NI resource path") }
    }
    public static func content(_ path: String) throws {
        let url = URL(fileURLWithPath: path)
        guard path.hasPrefix("/"), url.standardizedFileURL.path == path, url.pathComponents.count > 3,
              !["/System", "/Library", "/Applications", "/usr", "/bin", "/sbin", "/dev", "/etc", "/private/etc", "/private/var/db", "/private/var/root", "/Users/Shared/NI Resources"].contains(where: { path == $0 || path.hasPrefix($0 + "/") }), !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { throw MachineError.invalid("Unsafe library content location") }
    }
}
public enum RegistrationPhase: String, Codable, Sendable { case absent, prepared, applied, committed, rolledBack }
public protocol PrivilegedService: Sendable {
    func preflight() async throws
    func apply(_ request: RegistrationRequest) async throws
    func verify(_ request: RegistrationRequest) async throws
    func finish(_ transaction: UUID) async throws
    func rollback(_ transaction: UUID) async throws
    func phase(_ transaction: UUID) async throws -> RegistrationPhase
    func swapShared(_ request: SharedContentRequest) async throws
    func restoreShared(_ request: SharedContentRequest) async throws
    func cleanupShared(_ request: SharedContentRequest) async throws
}
public extension PrivilegedService {
    func swapShared(_ request: SharedContentRequest) async throws { throw MachineError.unavailable("Shared library privilege is unavailable") }
    func restoreShared(_ request: SharedContentRequest) async throws { throw MachineError.unavailable("Shared library privilege is unavailable") }
    func cleanupShared(_ request: SharedContentRequest) async throws { throw MachineError.unavailable("Shared library privilege is unavailable") }
}
public struct RegistrationBuilder {
    public static func build(metadata: RegistrationMetadata, content: URL, transaction: UUID = UUID(), resourcesRoot: URL? = nil) throws -> RegistrationRequest {
        var files: [ResourceFile] = []
        let imageRoot = resourcesRoot ?? content.appendingPathComponent("PAResources/image")
        if SafeTree.isDirectory(imageRoot) {
            let directories = try SafeTree.children(imageRoot).filter(SafeTree.isDirectory)
            let matching = directories.filter { ProductName.key($0.lastPathComponent) == ProductName.key(metadata.name) }
            // A single resource group is common for concatenated and multipart product folder names.
            let groups = matching.isEmpty && directories.count == 1 ? directories : matching
            for group in groups {
                try SafeTree.walk(group) { url in
                    if !SafeTree.isDirectory(url) {
                        let path = String(url.path.dropFirst(group.path.count + 1))
                        guard files.count < 2048 else { throw MachineError.invalid("Too many artwork files") }
                        let directory = try SecureDirectory(root: group, create: false)
                        guard let (data, _) = try directory.read(path, maximum: 16 * 1024 * 1024, createParents: false), files.reduce(data.count, { $0 + $1.data.count }) <= 48 * 1024 * 1024 else { throw MachineError.invalid("Artwork files exceed safety limits") }
                        files.append(ResourceFile(path: path, data: data))
                    }; return true
                }
            }
        }
        let request = RegistrationRequest(transaction: transaction, product: metadata.name, contentPath: content.path, version: metadata.version ?? "1.0.0", xml: metadata.xml, resources: files)
        try request.validate(); return request
    }
}
