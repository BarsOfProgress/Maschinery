import Foundation

/// Store metadata only. Local installation state remains in InstalledLibrary.
public struct CatalogueProduct: Codable, Identifiable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let productURL: URL
    public let artworkURL: URL?
    public let category: String?
    public var summary: String? = nil
    public let releaseDate: String?
    public let availability: String
    public var aliases: [String]
    /// Namespaced NI identifiers, never a Shopify ID guessed to be an NI ID.
    public var nativeIDs: [String]
}
public struct CatalogueSnapshot: Codable, Sendable {
    public let schemaVersion: Int
    public let sourceURL: URL
    public let fetchedAt: Date
    public let declaredCount: Int
    public let complete: Bool
    public let products: [CatalogueProduct]

    public static let source = URL(string: "https://www.native-instruments.com/collections/maschine-expansions")!
    public static func decoder() -> JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }
    public static func encoder() -> JSONEncoder { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.prettyPrinted, .sortedKeys]; return e }
    public func validate(previous: CatalogueSnapshot? = nil) throws {
        guard schemaVersion == 1, sourceURL == Self.source, complete, declaredCount > 0, declaredCount <= 5000,
              products.count == declaredCount, Set(products.map(\.id)).count == products.count,
              Set(products.map { CatalogueMatching.key($0.name) }).count == products.count else {
            throw MaschineryError.invalid("Catalogue is empty, incomplete, duplicated or unsupported")
        }
        for p in products {
            guard !p.id.isEmpty, p.id.count < 200, !CatalogueMatching.key(p.name).isEmpty, p.name.count < 200,
                  CatalogueURL.isProduct(p.productURL), p.artworkURL.map(CatalogueURL.isArtwork) ?? true,
                  p.aliases.count < 32, p.nativeIDs.count < 32,
                  p.aliases.allSatisfy({ !$0.isEmpty && $0.count < 200 }),
                  p.nativeIDs.allSatisfy({ ($0.hasPrefix("ni:upid:") || $0.hasPrefix("ni:regkey:")) && $0.count < 200 }) else { throw MaschineryError.invalid("Invalid official catalogue product") }
        }
        if let previous, products.count < previous.products.count - max(2, previous.products.count / 20) {
            throw MaschineryError.invalid("Catalogue shrank unexpectedly; keeping the last complete catalogue")
        }
    }
    public static func bundled() throws -> CatalogueSnapshot {
        // Packaged SwiftPM executables receive a top-level copy; prefer it so
        // resource lookup remains relocatable outside the developer workspace.
        if let url = Bundle.main.url(forResource: "ExpansionCatalogue", withExtension: "json") {
            let result = try decoder().decode(Self.self, from: Data(contentsOf: url)); try result.validate(); return result
        }
        #if SWIFT_PACKAGE
        let url = Bundle.module.url(forResource: "ExpansionCatalogue", withExtension: "json")
        #else
        let url = Bundle.main.url(forResource: "ExpansionCatalogue", withExtension: "json")
        #endif
        guard let url else { throw MaschineryError.unavailable("Bundled catalogue is unavailable") }
        let result = try decoder().decode(Self.self, from: Data(contentsOf: url)); try result.validate(); return result
    }
}
public enum CatalogueURL {
    public static func isProduct(_ url: URL) -> Bool {
        url.scheme == "https" && url.host == "www.native-instruments.com" && url.port == nil && url.user == nil && url.password == nil &&
        url.path.hasPrefix("/products/") && url.pathComponents.count == 3 && url.query == nil && url.fragment == nil
    }
    public static func isArtwork(_ url: URL) -> Bool {
        guard url.scheme == "https", url.user == nil, url.password == nil, url.port == nil else { return false }
        return (url.host == "www.native-instruments.com" && url.path.hasPrefix("/cdn/shop/files/")) ||
            (url.host == "cdn.shopify.com" && url.path.hasPrefix("/s/files/"))
    }
}

/// Reads the public CollectionPage JSON-LD, not an undocumented API or executable JavaScript.
public enum CatalogueParser {
    public struct Page: Sendable {
        public let products: [CatalogueProduct]
        public let positions: [Int]
        public let total: Int
        public let linkedPages: Set<Int>
    }
    static func captures(_ pattern: String, _ text: String) throws -> [[String]] {
        let expression = try NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators, .caseInsensitive])
        return expression.matches(in: text, range: NSRange(text.startIndex..., in: text)).map { m in
            (1..<m.numberOfRanges).map { Range(m.range(at: $0), in: text).map { String(text[$0]) } ?? "" }
        }
    }
    public static func parse(_ data: Data) throws -> Page {
        guard data.count <= 8 * 1024 * 1024, let html = String(data: data, encoding: .utf8) else { throw MaschineryError.invalid("Catalogue HTML exceeds limits or is not UTF-8") }
        let scripts = try captures(#"<script\b([^>]*)>(.*?)</script\s*>"#, html)
        var collection: [String: Any]?
        for script in scripts where script[0].lowercased().contains("application/ld+json") {
            guard let data = script[1].data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) else { continue }
            let objects = (object as? [[String: Any]]) ?? (object as? [String: Any]).map { [$0] } ?? []
            for value in objects where value["@type"] as? String == "CollectionPage" && value["url"] as? String == CatalogueSnapshot.source.absoluteString {
                guard collection == nil else { throw MaschineryError.invalid("Multiple catalogue lists in response") }; collection = value
            }
        }
        guard let collection, collection["name"] as? String == "Maschine Expansions",
              let list = collection["mainEntity"] as? [String: Any], list["@type"] as? String == "ItemList",
              let total = list["numberOfItems"] as? Int, total > 0, total <= 5000,
              let items = list["itemListElement"] as? [[String: Any]], !items.isEmpty else { throw MaschineryError.invalid("Official collection metadata is missing or empty") }
        // This public, JSON-valued theme metadata supplies stable Shopify IDs and
        // variant classification. It is decoded, never evaluated as JavaScript.
        guard let metaText = try captures(#"\bvar\s+meta\s*=\s*(\{.*?\});"#, html).first?.first,
              let metaData = metaText.data(using: .utf8),
              let meta = try JSONSerialization.jsonObject(with: metaData) as? [String: Any],
              let metadata = meta["products"] as? [[String: Any]] else { throw MaschineryError.invalid("Catalogue product identities are missing") }
        var summaries: [String: String] = [:]
        for card in try captures(#"<product-card\b[^>]*>(.*?)</product-card\s*>"#, html) {
            if let path = try captures(#"href=["'](/products/[^"'?]+)"#, card[0]).first?.first,
               let description = try captures(#"<span\b[^>]*class=["']metafield-multi_line_text_field["'][^>]*>(.*?)</span>"#, card[0]).first?.first {
                summaries[path] = description.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
                    .replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&#39;", with: "'")
                    .replacingOccurrences(of: "&quot;", with: "\"").trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        var products: [CatalogueProduct] = [], positions: [Int] = []
        for entry in items {
            guard let p = entry["item"] as? [String: Any], p["@type"] as? String == "Product",
                  let name = p["name"] as? String, let text = p["url"] as? String, let url = URL(string: text), CatalogueURL.isProduct(url),
                  let position = entry["position"] as? Int, position > 0, position <= total,
                  let info = metadata.first(where: { $0["handle"] as? String == url.lastPathComponent }),
                  info["vendor"] as? String == "Native Instruments", let number = info["id"] as? NSNumber,
                  let variants = info["variants"] as? [[String: Any]],
                  variants.contains(where: { ($0["public_title"] as? String)?.hasPrefix("Expansion - ") == true }) else {
                throw MaschineryError.invalid("Collection contains an unclassified product; keeping the previous catalogue")
            }
            let image: URL?
            if let text = p["image"] as? String { image = URL(string: text); guard image.map(CatalogueURL.isArtwork) == true else { throw MaschineryError.invalid("Unexpected artwork source") } }
            else { image = nil }
            let offers = p["offers"] as? [String: Any]
            products.append(CatalogueProduct(id: "shopify:" + number.stringValue, name: name, productURL: url, artworkURL: image,
                category: p["category"] as? String, summary: (p["description"] as? String) ?? summaries[url.path], releaseDate: p["releaseDate"] as? String,
                availability: (offers?["availability"] as? String)?.components(separatedBy: "/").last ?? "unknown", aliases: [], nativeIDs: []))
            positions.append(position)
        }
        let links = try captures(#"/collections/maschine-expansions\?page=(\d+)"#, html).compactMap { Int($0[0]) }
        guard links.allSatisfy({ (1...100).contains($0) }) else { throw MaschineryError.invalid("Unexpected catalogue pagination") }
        return Page(products: products, positions: positions, total: total, linkedPages: Set(links))
    }
    public static func combine(_ pages: [Page], date: Date = Date()) throws -> CatalogueSnapshot {
        guard let total = pages.first?.total, pages.allSatisfy({ $0.total == total }) else { throw MaschineryError.invalid("Collection changed during refresh; retry later") }
        let products = pages.flatMap(\.products)
        // NI restarts ListItem positions at 1 on every page. Check each page
        // independently, then verify unique products against the declared total.
        guard pages.allSatisfy({ $0.positions.sorted() == Array(1...$0.products.count) }), products.count == total else { throw MaschineryError.invalid("Catalogue pages are incomplete or repeated") }
        let result = CatalogueSnapshot(schemaVersion: 1, sourceURL: CatalogueSnapshot.source, fetchedAt: date, declaredCount: total, complete: true, products: products)
        try result.validate(); return result
    }
}

/// Shared bounded, read-only transport. No cookies, account data, or installer API.
public enum CatalogueHTTP {
    public static func fetch(_ url: URL, maximum: Int = 8 * 1024 * 1024) async throws -> Data {
        var request = URLRequest(url: url); request.timeoutInterval = 25
        request.setValue("Maschinery/1.0 Catalogue (+https://www.native-instruments.com/collections/maschine-expansions)", forHTTPHeaderField: "User-Agent")
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForResource = 40; config.httpMaximumConnectionsPerHost = 2
        config.httpShouldSetCookies = false; config.urlCredentialStorage = nil
        let session = URLSession(configuration: config); defer { session.invalidateAndCancel() }
        let (file, response) = try await session.download(for: request)
        defer { try? FileManager.default.removeItem(at: file) }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200, let final = http.url,
              final.host == url.host, final.scheme == "https",
              response.expectedContentLength <= maximum,
              (try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? maximum + 1) <= maximum else {
            throw MaschineryError.unavailable("Official catalogue or artwork request failed; cached data is retained")
        }
        try Task.checkCancellation(); return try Data(contentsOf: file)
    }
}
public actor CatalogueService {
    public typealias Fetch = @Sendable (URL) async throws -> Data
    public let root: URL
    private let fetch: Fetch
    private let baseline: CatalogueSnapshot?
    private var snapshot: CatalogueSnapshot?
    private var lastAttempt: Date?
    public init(root: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Maschinery/Catalogue"), baseline: CatalogueSnapshot? = try? CatalogueSnapshot.bundled(), fetch: @escaping Fetch = { try await CatalogueHTTP.fetch($0) }) {
        self.root = root; self.baseline = baseline; self.fetch = fetch
    }
    public func load() -> (snapshot: CatalogueSnapshot?, bundled: Bool) {
        let file = root.appendingPathComponent("catalogue.json")
        if let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 8 * 1024 * 1024,
           let data = try? Data(contentsOf: file), let cached = try? CatalogueSnapshot.decoder().decode(CatalogueSnapshot.self, from: data),
           (try? cached.validate(previous: baseline)) != nil {
            snapshot = cached; return (cached, false)
        }
        snapshot = baseline; return (baseline, true)
    }
    public func refresh(offline: Bool, force: Bool, interval: TimeInterval = 86400, now: Date = Date()) async throws -> CatalogueSnapshot? {
        if snapshot == nil { _ = load() }
        guard !offline else { return snapshot }
        let interval = max(3600, min(interval, 30 * 86400))
        if !force, let snapshot, now.timeIntervalSince(snapshot.fetchedAt) < interval { return snapshot }
        if !force, let lastAttempt, now.timeIntervalSince(lastAttempt) < 3600 { return snapshot }
        lastAttempt = now
        var pending = Set([1]), seen = Set<Int>(), pages: [CatalogueParser.Page] = []
        while let page = pending.sorted().first {
            try Task.checkCancellation(); pending.remove(page)
            guard seen.insert(page).inserted, seen.count <= 100 else { throw MaschineryError.invalid("Catalogue pagination did not terminate") }
            let url = page == 1 ? CatalogueSnapshot.source : URL(string: CatalogueSnapshot.source.absoluteString + "?page=\(page)")!
            let parsed = try CatalogueParser.parse(try await fetch(url)); pages.append(parsed)
            pending.formUnion(parsed.linkedPages.subtracting(seen))
            if !pending.isEmpty { try await Task.sleep(for: .milliseconds(500)) }
        }
        let parsed = try CatalogueParser.combine(pages, date: now)
        // Verified naming aliases and NI-ID mappings are maintained in the
        // bundled manifest, never inferred from a store SKU or fuzzy similarity.
        let approved = Dictionary(uniqueKeysWithValues: (baseline?.products ?? []).map { ($0.id, $0) })
        let products = parsed.products.map { value in
            var product = value
            if let known = approved[value.id] { product.aliases = known.aliases; product.nativeIDs = known.nativeIDs }
            return product
        }
        let result = CatalogueSnapshot(schemaVersion: parsed.schemaVersion, sourceURL: parsed.sourceURL, fetchedAt: parsed.fetchedAt, declaredCount: parsed.declaredCount, complete: parsed.complete, products: products)
        try result.validate(previous: snapshot)
        try SafeTree.validate(root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try CatalogueSnapshot.encoder().encode(result).write(to: root.appendingPathComponent("catalogue.json"), options: .atomic)
        snapshot = result; return result
    }
}
