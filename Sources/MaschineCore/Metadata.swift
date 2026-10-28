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
    public static func parse(_ data: Data, source: MetadataSource) throws -> [RegistrationMetadata] {
        guard data.count <= 32 * 1024 * 1024 else { throw MachineError.invalid("XML exceeds 32 MB safety limit") }
        // Reject external entities/DTDs before FoundationXML parses untrusted input.
        guard let text = String(data: data, encoding: .utf8), !text.uppercased().contains("<!DOCTYPE"), !text.uppercased().contains("<!ENTITY") else { throw MachineError.invalid("Unsupported XML encoding or entity declaration") }
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
    public init() {}
    public func clear() { cached = nil }
    public func records(offline: Bool) async throws -> [RegistrationMetadata] {
        guard !offline else { return [] }
        if let cached { return cached }
        if let request { return try await request.value }
        let task = Task<[RegistrationMetadata], Error> {
            var request = URLRequest(url: URL(string: "https://api.native-instruments.com/static/phints")!); request.timeoutInterval = 15
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw MachineError.unavailable("ProductHints returned an unsuccessful HTTP response") }
            return try MetadataXML.parse(data, source: .productHints)
        }
        request = task
        do { let result = try await task.value; cached = result; request = nil; return result }
        catch { request = nil; throw error }
    }
}
