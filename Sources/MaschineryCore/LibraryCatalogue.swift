import Foundation

public enum LibraryFilter: String, CaseIterable, Sendable { case all = "All", installed = "Installed", missing = "Missing" }
public enum LibrarySort: String, CaseIterable, Sendable { case ascending = "Name A–Z", descending = "Name Z–A" }
/// A presentation projection over store metadata and the existing local audit model.
/// Multiple registrations are retained for management, never silently discarded.
public struct LibraryCatalogueEntry: Identifiable, Sendable {
    public let id: String
    public let product: CatalogueProduct?
    public var registrations: [InstalledLibrary]
    public var name: String { product?.name ?? registrations.first?.name ?? "Unknown expansion" }
    public var installed: Bool { registrations.contains { $0.content != nil && !$0.issues.contains(.missingContent) } }
    public var unlisted: Bool { product == nil }
}
public struct CollectionStatistics: Sendable {
    public let installed: Int
    public let total: Int
    public var missing: Int { total - installed }
    public var percentage: Int? { total > 0 ? Int((Double(installed) / Double(total) * 100).rounded()) : nil }
    public init(entries: [LibraryCatalogueEntry]) {
        let catalogue = entries.filter { $0.product != nil }
        total = catalogue.count; installed = catalogue.filter(\.installed).count
    }
}
public enum CatalogueMatching {
    public static func key(_ value: String) -> String { ProductName.key(value) }
    public static func entries(products: [CatalogueProduct], installed: [InstalledLibrary]) -> [LibraryCatalogueEntry] {
        var rows = products.map { LibraryCatalogueEntry(id: $0.id, product: $0, registrations: []) }
        var byIdentifier: [String: Set<Int>] = [:], byName: [String: Set<Int>] = [:], byAlias: [String: Set<Int>] = [:]
        let identifiers = products.map { Set($0.nativeIDs) }
        for (index, product) in products.enumerated() {
            byName[key(product.name), default: []].insert(index)
            for alias in product.aliases { byAlias[key(alias), default: []].insert(index) }
            for identifier in product.nativeIDs { byIdentifier[identifier, default: []].insert(index) }
        }
        var unlisted: [String: [InstalledLibrary]] = [:]
        for local in installed {
            let localIDs = Set(local.nativeIDs), name = key(local.name)
            let idMatches = localIDs.reduce(into: Set<Int>()) { $0.formUnion(byIdentifier[$1] ?? []) }
            let compatible: (Int) -> Bool = { identifiers[$0].isEmpty || localIDs.isEmpty || !identifiers[$0].isDisjoint(with: localIDs) }
            let nameMatches = (byName[name] ?? []).filter(compatible)
            let aliasMatches = (byAlias[name] ?? []).filter(compatible)
            // A supplied but ambiguous identifier never falls back to a guessed name.
            let matches = !idMatches.isEmpty ? idMatches : (!nameMatches.isEmpty ? nameMatches : aliasMatches)
            if matches.count == 1, let index = matches.first { rows[index].registrations.append(local) }
            else { unlisted[name, default: []].append(local) }
        }
        rows += unlisted.sorted { $0.key < $1.key }.map { LibraryCatalogueEntry(id: "local:" + $0.key, product: nil, registrations: $0.value.sorted { $0.id.path < $1.id.path }) }
        return rows.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    public static func filter(_ entries: [LibraryCatalogueEntry], query: String, filter: LibraryFilter, sort: LibrarySort) -> [LibraryCatalogueEntry] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedQuery = key(query)
        return entries.filter { row in
            let visible = filter == .all || (filter == .installed && row.installed) || (filter == .missing && row.product != nil && !row.installed)
            let searchable = [row.name, row.product?.category ?? ""] + (row.product?.aliases ?? []) + row.registrations.map(\.name)
            return visible && (query.isEmpty || searchable.contains { $0.localizedStandardContains(query) || !normalizedQuery.isEmpty && key($0).contains(normalizedQuery) })
        }.sorted { a, b in
            let comparison = a.name.localizedStandardCompare(b.name)
            if comparison == .orderedSame { return a.id < b.id }
            return sort == .ascending ? comparison == .orderedAscending : comparison == .orderedDescending
        }
    }
}
