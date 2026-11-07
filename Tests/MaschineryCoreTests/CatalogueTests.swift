import XCTest
@testable import MaschineryCore

private actor CatalogueFetchRecorder {
    var calls: [URL] = []
    let pages: [Int: Data]
    let failure: Bool
    init(pages: [Int: Data] = [:], failure: Bool = false) { self.pages = pages; self.failure = failure }
    func fetch(_ url: URL) throws -> Data {
        calls.append(url)
        if failure { throw URLError(.notConnectedToInternet) }
        let page = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "page" })?.value.flatMap(Int.init) ?? 1
        guard let data = pages[page] else { throw URLError(.badServerResponse) }; return data
    }
    func count() -> Int { calls.count }
}
final class CatalogueTests: XCTestCase {
    func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }; return root
    }
    func pages() throws -> [Int: Data] {
        var result: [Int: Data] = [:]
        let root = try XCTUnwrap(Bundle.module.url(forResource: "Fixtures", withExtension: nil))
        for file in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) where file.lastPathComponent.hasPrefix("collection-page-") {
            let number = try XCTUnwrap(Int(file.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "collection-page-", with: "")))
            result[number] = try Data(contentsOf: file)
        }
        return result
    }
    func product(_ name: String, id: String? = nil, aliases: [String] = [], nativeIDs: [String] = []) -> CatalogueProduct {
        CatalogueProduct(id: id ?? "test:" + name, name: name, productURL: URL(string: "https://www.native-instruments.com/products/" + CatalogueMatching.key(name))!, artworkURL: nil, category: nil, releaseDate: nil, availability: "InStock", aliases: aliases, nativeIDs: nativeIDs)
    }
    func local(_ name: String, suffix: String = "", issues: [LibraryIssue] = [], nativeIDs: [String] = []) -> InstalledLibrary {
        InstalledLibrary(id: URL(fileURLWithPath: "/tmp/prefs/" + name + suffix + ".plist"), name: name, nativeIDs: nativeIDs, content: URL(fileURLWithPath: "/tmp/content/" + name), version: "1", artwork: nil, issues: issues)
    }
    func snapshot(_ products: [CatalogueProduct], count: Int? = nil, complete: Bool = true, date: Date = Date()) -> CatalogueSnapshot {
        CatalogueSnapshot(schemaVersion: 1, sourceURL: CatalogueSnapshot.source, fetchedAt: date, declaredCount: count ?? products.count, complete: complete, products: products)
    }
    func testLiveCatalogueAndOfficialArtworkWhenRequested() async throws {
        guard ProcessInfo.processInfo.environment["MASCHINERY_LIVE_CATALOGUE"] == "1" else { throw XCTSkip("Live store verification is opt-in; recorded fixtures cover normal tests") }
        let root = try fixture()
        let service = CatalogueService(root: root, baseline: nil)
        let refreshed = try await service.refresh(offline: false, force: true)
        let snapshot = try XCTUnwrap(refreshed)
        try snapshot.validate()
        let url = try XCTUnwrap(snapshot.products.first?.artworkURL)
        let cache = OfficialArtworkCache(root: root.appendingPathComponent("artwork"))
        let file = await cache.file(for: url, offline: false)
        XCTAssertNotNil(file)
        if let file {
            let thumbnail = await ArtworkThumbnailCache.shared.thumbnail(at: file)
            XCTAssertNotNil(thumbnail)
        }
        let offline = await cache.file(for: url, offline: true)
        XCTAssertEqual(file, offline)
        print("LIVE VERIFIED: \(snapshot.products.count) unique catalogue products; first official artwork downloaded, decoded and reused offline")
    }
    func testRecordedCollectionAllPagesMatchBundledManifest() throws {
        let recorded = try pages(), parsed = try recorded.keys.sorted().map { try CatalogueParser.parse(recorded[$0]!) }
        let combined = try CatalogueParser.combine(parsed), bundled = try CatalogueSnapshot.bundled()
        XCTAssertEqual(combined.products.count, combined.declaredCount)
        XCTAssertEqual(combined.products, bundled.products)
        XCTAssertTrue(combined.products.allSatisfy { $0.artworkURL != nil && $0.summary != nil })
        XCTAssertEqual(Set(combined.products.map(\.id)).count, combined.products.count)
        XCTAssertTrue(combined.products.contains { $0.name == "Maschine Central" })
    }
    func testExactNameNormalizationAndRegistrationGrouping() {
        let rows = CatalogueMatching.entries(products: [product("Deep Matter")], installed: [local("DEEP_MATTER Library"), local("Deep-Matter", suffix: "two")])
        XCTAssertEqual(rows.count, 1); XCTAssertTrue(rows[0].installed); XCTAssertEqual(rows[0].registrations.count, 2)
        XCTAssertEqual(CatalogueMatching.key("  Café – Beats! "), CatalogueMatching.key("cafe beats"))
    }
    func testAliasesAndIdentifiersTakePriorityWithoutFuzzyMatching() {
        let rows = CatalogueMatching.entries(products: [product("New Name", aliases: ["Legacy Name"], nativeIDs: ["ni:upid:abc"])], installed: [local("Legacy Name"), local("Unrelated Display", nativeIDs: ["ni:upid:abc"]), local("New Names")])
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows.first { $0.product != nil }?.registrations.count, 2)
        XCTAssertEqual(rows.first { $0.unlisted }?.name, "New Names")
    }
    func testLocalNIIdentifiersRequireSingleMatchingProductMetadata() throws {
        let root = try fixture(), prefs = root.appendingPathComponent("prefs"), xml = root.appendingPathComponent("xml"), content = root.appendingPathComponent("content")
        let fm = FileManager.default
        for url in [prefs, xml, content] { try fm.createDirectory(at: url, withIntermediateDirectories: true) }
        let plist = try PropertyListSerialization.data(fromPropertyList: ["ContentDir": content.path], format: .xml, options: 0)
        try plist.write(to: prefs.appendingPathComponent("com.native-instruments.Test.plist"))
        let product = "<Product><Name>Test</Name><UPID>ABC</UPID><RegKey>Test Key</RegKey></Product>"
        let file = xml.appendingPathComponent("Test.xml")
        try Data(("<ProductHints>" + product + "</ProductHints>").utf8).write(to: file)
        let first = try ExistingLibraryService.audit(preferences: prefs, serviceCenter: xml, resources: root.appendingPathComponent("images"))
        XCTAssertEqual(first.first?.nativeIDs.sorted(), ["ni:regkey:test key", "ni:upid:abc"])
        try Data(("<ProductHints>" + product + "<Product><Name>Other</Name><UPID>unrelated</UPID></Product></ProductHints>").utf8).write(to: file)
        let ambiguous = try ExistingLibraryService.audit(preferences: prefs, serviceCenter: xml, resources: root.appendingPathComponent("images"))
        XCTAssertEqual(ambiguous.first?.nativeIDs, [])
    }
    func testConflictingExplicitNIIdentifiersDoNotFallBackToName() {
        let rows = CatalogueMatching.entries(products: [product("Same Name", nativeIDs: ["ni:upid:official"])], installed: [local("Same Name", nativeIDs: ["ni:upid:different"])])
        XCTAssertEqual(rows.count, 2)
        XCTAssertFalse(rows.first { $0.product != nil }!.installed)
        XCTAssertTrue(rows.first { $0.unlisted }!.installed)
    }
    func testMaintainedAliasesAndNIMappingsSurviveRefresh() async throws {
        let root = try fixture(), original = try CatalogueSnapshot.bundled(), recorded = try pages()
        var products = original.products
        products[0].aliases = ["Verified Legacy Display Name"]
        products[0].nativeIDs = ["ni:upid:verified-test-id"]
        let baseline = snapshot(products)
        let recorder = CatalogueFetchRecorder(pages: recorded)
        let service = CatalogueService(root: root, baseline: baseline, fetch: { try await recorder.fetch($0) })
        let result = try await service.refresh(offline: false, force: true)
        XCTAssertEqual(result?.products.first?.aliases, products[0].aliases)
        XCTAssertEqual(result?.products.first?.nativeIDs, products[0].nativeIDs)
        let restarted = CatalogueService(root: root, baseline: baseline, fetch: { _ in throw URLError(.notConnectedToInternet) })
        let loaded = await restarted.load()
        XCTAssertEqual(loaded.snapshot?.products.first?.aliases, products[0].aliases)
    }
    func testAmbiguousAliasesAreNotAutomaticallyMerged() {
        let rows = CatalogueMatching.entries(products: [product("A", aliases: ["Old"]), product("B", aliases: ["Old"])], installed: [local("Old")])
        XCTAssertEqual(rows.filter(\.installed).count, 1)
        XCTAssertTrue(rows.first { $0.installed }!.unlisted)
    }
    func testUnknownLocalsAndMissingDetectionKeepAllManagementRecords() {
        let rows = CatalogueMatching.entries(products: [product("A"), product("B")], installed: [local("A"), local("Retired"), local("B", issues: [.missingContent])])
        XCTAssertEqual(rows.count, 3)
        let b = rows.first { $0.name == "B" }!
        XCTAssertFalse(b.installed); XCTAssertEqual(b.registrations.count, 1)
        let stats = CollectionStatistics(entries: rows)
        XCTAssertEqual(stats.total, 2); XCTAssertEqual(stats.installed, 1); XCTAssertEqual(stats.missing, 1); XCTAssertEqual(stats.percentage, 50)
    }
    func testHundredsOfEntriesKeepStableIdentityRegardlessOfAuditOrder() {
        let products = (0..<400).map { product("Expansion \($0)", id: "store:\($0)") }
        let locals = (0..<300).map { local("Expansion \($0)") }
        let first = CatalogueMatching.entries(products: products, installed: locals)
        let reversed = CatalogueMatching.entries(products: products, installed: Array(locals.reversed()))
        XCTAssertEqual(first.map(\.id), reversed.map(\.id))
        XCTAssertEqual(first.count, products.count)
        let stats = CollectionStatistics(entries: first)
        XCTAssertEqual(stats.installed, 300); XCTAssertEqual(stats.missing, 100); XCTAssertEqual(stats.percentage, 75)
    }
    func testSearchAndEveryFilterAndSortingPreserveInput() {
        let rows = CatalogueMatching.entries(products: [product("Alpha"), product("Beta", aliases: ["Second"]), product("Gamma")], installed: [local("Alpha"), local("Unlisted")])
        XCTAssertEqual(CatalogueMatching.filter(rows, query: "", filter: .all, sort: .ascending).map(\.name), ["Alpha", "Beta", "Gamma", "Unlisted"])
        XCTAssertEqual(CatalogueMatching.filter(rows, query: "a", filter: .installed, sort: .ascending).map(\.name), ["Alpha"])
        XCTAssertEqual(CatalogueMatching.filter(rows, query: "a", filter: .missing, sort: .descending).map(\.name), ["Gamma", "Beta"])
        XCTAssertEqual(CatalogueMatching.filter(rows, query: "second", filter: .missing, sort: .ascending).map(\.name), ["Beta"])
        XCTAssertTrue(CatalogueMatching.filter(rows, query: "Second", filter: .installed, sort: .ascending).isEmpty)
        XCTAssertNil(CollectionStatistics(entries: []).percentage)
    }
    func testDuplicateEmptyMalformedAndIncompleteCataloguesRejected() throws {
        let p = product("A")
        XCTAssertThrowsError(try snapshot([]).validate())
        XCTAssertThrowsError(try snapshot([p, p]).validate())
        XCTAssertThrowsError(try snapshot([p], count: 2).validate())
        XCTAssertThrowsError(try snapshot([p], complete: false).validate())
        XCTAssertThrowsError(try CatalogueParser.parse(Data("<html>Access unavailable</html>".utf8)))
        let first = try CatalogueParser.parse(try XCTUnwrap(pages()[1]))
        XCTAssertThrowsError(try CatalogueParser.combine([first]))
        XCTAssertThrowsError(try CatalogueParser.combine([first, first]))
    }
    func testHardwareClassificationAndUntrustedProductURLsRejected() throws {
        let data = try XCTUnwrap(pages()[1]), text = try XCTUnwrap(String(data: data, encoding: .utf8))
        let hardware = text.replacingOccurrences(of: "Expansion - ", with: "Controller - ")
        XCTAssertThrowsError(try CatalogueParser.parse(Data(hardware.utf8)))
        let unsafe = text.replacingOccurrences(of: "https://www.native-instruments.com/products/", with: "https://example.com/products/")
        XCTAssertThrowsError(try CatalogueParser.parse(Data(unsafe.utf8)))
        XCTAssertFalse(CatalogueURL.isArtwork(URL(string: "https://www.native-instruments.com.example.com/cdn/shop/files/test.png")!))
        XCTAssertFalse(CatalogueURL.isArtwork(URL(string: "file:///tmp/image.png")!))
    }
    func testSuspiciousShrinkRejectedEvenWithConsistentDeclaredTotal() throws {
        let previous = snapshot((0..<20).map { product("Expansion \($0)") })
        XCTAssertThrowsError(try snapshot([product("A")]).validate(previous: previous))
    }
    func testRefreshPersistsAcrossRestartAndOfflineUsesCache() async throws {
        let root = try fixture(), recorded = try pages(), recorder = CatalogueFetchRecorder(pages: recorded)
        let service = CatalogueService(root: root, baseline: nil, fetch: { try await recorder.fetch($0) })
        let fresh = try await service.refresh(offline: false, force: true)
        let count = await recorder.count(); XCTAssertEqual(count, recorded.count)
        let failure = CatalogueFetchRecorder(failure: true)
        let restarted = CatalogueService(root: root, baseline: nil, fetch: { try await failure.fetch($0) })
        let loaded = await restarted.load(); XCTAssertFalse(loaded.bundled)
        XCTAssertEqual(loaded.snapshot?.products, fresh?.products)
        let offline = try await restarted.refresh(offline: true, force: true)
        XCTAssertEqual(try XCTUnwrap(offline).fetchedAt.timeIntervalSince1970, try XCTUnwrap(fresh).fetchedAt.timeIntervalSince1970, accuracy: 1)
        let failures = await failure.count(); XCTAssertEqual(failures, 0)
    }
    func testNetworkFailureKeepsLastValidFileAndFailureBackoff() async throws {
        let root = try fixture(), baseline = try CatalogueSnapshot.bundled()
        try CatalogueSnapshot.encoder().encode(baseline).write(to: root.appendingPathComponent("catalogue.json"))
        let original = try Data(contentsOf: root.appendingPathComponent("catalogue.json"))
        let failure = CatalogueFetchRecorder(failure: true)
        let service = CatalogueService(root: root, baseline: baseline, fetch: { try await failure.fetch($0) })
        let now = baseline.fetchedAt.addingTimeInterval(90_000)
        do { _ = try await service.refresh(offline: false, force: true, now: now); XCTFail("Expected network failure") } catch {}
        let loaded = await service.load(); XCTAssertEqual(loaded.snapshot?.products, baseline.products)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("catalogue.json")), original)
        _ = try await service.refresh(offline: false, force: false, now: now.addingTimeInterval(10))
        let calls = await failure.count(); XCTAssertEqual(calls, 1)
    }
    func testPartialRefreshNeverReplacesCompleteCache() async throws {
        let root = try fixture(), baseline = try CatalogueSnapshot.bundled(), first = try XCTUnwrap(pages()[1])
        let service = CatalogueService(root: root, baseline: baseline, fetch: { _ in first })
        do { _ = try await service.refresh(offline: false, force: true); XCTFail("Repeated page must fail") } catch {}
        let loaded = await service.load(); XCTAssertEqual(loaded.snapshot?.products, baseline.products)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("catalogue.json").path))
    }
    func testCorruptCacheFallsBackAndRefreshIntervalAvoidsRequests() async throws {
        let root = try fixture(), baseline = try CatalogueSnapshot.bundled()
        try Data("{}".utf8).write(to: root.appendingPathComponent("catalogue.json"))
        let recorder = CatalogueFetchRecorder(failure: true)
        let service = CatalogueService(root: root, baseline: baseline, fetch: { try await recorder.fetch($0) })
        let loaded = await service.load(); XCTAssertTrue(loaded.bundled)
        let result = try await service.refresh(offline: false, force: false, interval: 86400, now: baseline.fetchedAt.addingTimeInterval(60))
        XCTAssertEqual(result?.products, baseline.products)
        let count = await recorder.count(); XCTAssertEqual(count, 0)
    }
    func testOfflineBaselineWorksWithoutCacheOrNetworking() async throws {
        let root = try fixture(), baseline = try CatalogueSnapshot.bundled(), recorder = CatalogueFetchRecorder(failure: true)
        let service = CatalogueService(root: root, baseline: baseline, fetch: { try await recorder.fetch($0) })
        let result = try await service.refresh(offline: true, force: true)
        XCTAssertEqual(result?.products.count, baseline.products.count)
        let count = await recorder.count(); XCTAssertEqual(count, 0)
    }
    func testOfficialArtworkDeduplicatesAndSurvivesRestartOffline() async throws {
        let root = try fixture(), image = root.appendingPathComponent("fixture.png")
        try SyntheticArtworkFixture.image(at: image)
        let data = try Data(contentsOf: image), recorder = CatalogueFetchRecorder(pages: [1: data])
        let cacheRoot = root.appendingPathComponent("cache"), url = URL(string: "https://www.native-instruments.com/cdn/shop/files/test.png?v=1&width=800")!
        let cache = OfficialArtworkCache(root: cacheRoot, fetch: { try await recorder.fetch($0) })
        async let a = cache.file(for: url, offline: false)
        async let b = cache.file(for: url, offline: false)
        let (first, second) = await (a, b)
        XCTAssertNotNil(first); XCTAssertEqual(first, second)
        let count = await recorder.count(); XCTAssertEqual(count, 1)
        let restarted = OfficialArtworkCache(root: cacheRoot, fetch: { _ in throw URLError(.notConnectedToInternet) })
        let offline = await restarted.file(for: url, offline: true)
        XCTAssertEqual(offline, first)
        let thumbnail = await ArtworkThumbnailCache.shared.thumbnail(at: try XCTUnwrap(offline))
        XCTAssertNotNil(thumbnail)
    }
    func testMissingCorruptArtworkOfflineAndRetryBackoff() async throws {
        let root = try fixture(), recorder = CatalogueFetchRecorder(pages: [1: Data("not an image".utf8)])
        let cache = OfficialArtworkCache(root: root, fetch: { try await recorder.fetch($0) })
        let url = URL(string: "https://www.native-instruments.com/cdn/shop/files/missing.png")!
        let noURL = await cache.file(for: nil, offline: false); XCTAssertNil(noURL)
        let offline = await cache.file(for: url, offline: true); XCTAssertNil(offline)
        let corrupt = await cache.file(for: url, offline: false); XCTAssertNil(corrupt)
        let again = await cache.file(for: url, offline: false); XCTAssertNil(again)
        let count = await recorder.count(); XCTAssertEqual(count, 1)
    }
    func testArtworkDiskBudgetAndVersionedURLInvalidation() async throws {
        let root = try fixture(), image = root.appendingPathComponent("fixture.png")
        try SyntheticArtworkFixture.image(at: image)
        let data = try Data(contentsOf: image), recorder = CatalogueFetchRecorder(pages: [1: data])
        let cacheRoot = root.appendingPathComponent("cache")
        let cache = OfficialArtworkCache(root: cacheRoot, budget: data.count + 10, fetch: { try await recorder.fetch($0) })
        let first = await cache.file(for: URL(string: "https://www.native-instruments.com/cdn/shop/files/cover.png?v=1")!, offline: false)
        let second = await cache.file(for: URL(string: "https://www.native-instruments.com/cdn/shop/files/cover.png?v=2")!, offline: false)
        XCTAssertNotEqual(first, second)
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(first).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(second).path))
        let count = await recorder.count(); XCTAssertEqual(count, 2)
    }
}
