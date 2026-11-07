import Foundation

public enum ProductName {
    public static func display(_ value: String) -> String {
        value.replacingOccurrences(of: #"(?i)(?:[ _-]*library)?[ _-]*part[ _-]*\d+$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)[ _-]*library$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "_", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }
    public static func key(_ value: String) -> String {
        display(value).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX")).filter { $0.isLetter || $0.isNumber }
    }
}
public enum MetadataMatch: Sendable { case matched(RegistrationMetadata), ambiguous([RegistrationMetadata]), unresolved }
public enum MetadataMatchingService {
    public static func match(_ name: String, in records: [RegistrationMetadata]) -> MetadataMatch {
        let matches = records.filter { ProductName.key($0.name) == ProductName.key(name) }
        guard let priority = matches.map(\.source.rawValue).max() else { return .unresolved }
        let best = Array(Set(matches.filter { $0.source.rawValue == priority }))
        return best.count == 1 ? .matched(best[0]) : .ambiguous(best)
    }
}
public enum MetadataXML {
    public static func read(_ url: URL, source: MetadataSource) throws -> [RegistrationMetadata] {
        let directory = try SecureDirectory(root: url.deletingLastPathComponent(), create: false)
        guard let (data, _) = try directory.read(url.lastPathComponent, maximum: 32 * 1024 * 1024, createParents: false) else { throw MaschineryError.invalid("XML file no longer exists") }
        return try parse(data, source: source)
    }
    public static func parse(_ data: Data, source: MetadataSource) throws -> [RegistrationMetadata] {
        guard data.count <= 32 * 1024 * 1024 else { throw MaschineryError.invalid("XML exceeds 32 MB safety limit") }
        // Reject external entities/DTDs before FoundationXML parses untrusted input.
        guard let text = String(data: data, encoding: .utf8), !text.uppercased().contains("<!DOCTYPE"), !text.uppercased().contains("<!ENTITY") else { throw MaschineryError.invalid("Unsupported XML encoding or entity declaration") }
        let doc = try XMLDocument(data: data, options: [.nodeLoadExternalEntitiesNever])
        let products = try doc.nodes(forXPath: "//*[local-name()='Product' or local-name()='product']")
        return products.compactMap { node in
            guard let element = node as? XMLElement else { return nil }
            let children = element.children ?? []
            guard let name = children.first(where: { $0.name?.lowercased() == "name" })?.stringValue, !name.isEmpty else { return nil }
            let version = children.first(where: { $0.name?.lowercased() == "contentversion" || $0.name?.lowercased() == "version" })?.stringValue
            let root = XMLElement(name: "ProductHints"); root.addChild(element.copy() as! XMLNode)
            return RegistrationMetadata(name: name, version: version, xml: XMLDocument(rootElement: root).xmlData, source: source)
        }
    }
}
public actor ProductHintsService {
    private var cached: [RegistrationMetadata]?
    private var request: Task<[RegistrationMetadata], Error>?
    private var generation = UUID()
    private let fetch: @Sendable () async throws -> Data
    public init(fetch: @escaping @Sendable () async throws -> Data = ProductHintsService.fetchNative) { self.fetch = fetch }
    public static func fetchNative() async throws -> Data {
        var request = URLRequest(url: URL(string: "https://api.native-instruments.com/static/phints")!); request.timeoutInterval = 15
        let (file, response) = try await URLSession.shared.download(for: request)
        defer { try? FileManager.default.removeItem(at: file) }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw MaschineryError.unavailable("ProductHints returned an unsuccessful HTTP response") }
        let directory = try SecureDirectory(root: file.deletingLastPathComponent(), create: false)
        guard let (data, _) = try directory.read(file.lastPathComponent, maximum: 32 * 1024 * 1024, createParents: false) else { throw MaschineryError.unavailable("ProductHints response disappeared") }
        return data
    }
    public func clear() { cached = nil; request?.cancel(); request = nil; generation = UUID() }
    public func records(offline: Bool) async throws -> [RegistrationMetadata] {
        guard !offline else { return [] }
        if let cached { return cached }
        if let request { return try await withTaskCancellationHandler { try await request.value } onCancel: { request.cancel() } }
        let fetch = fetch, epoch = generation
        let task = Task<[RegistrationMetadata], Error> { try MetadataXML.parse(try await fetch(), source: .productHints) }
        request = task
        do {
            let result = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            if epoch == generation { cached = result; request = nil }
            return result
        } catch { if epoch == generation { request = nil }; throw error }
    }
}
