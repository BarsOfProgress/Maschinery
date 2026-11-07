import XCTest
@testable import MaschineryCore

final class CoreTests: XCTestCase {
    func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }; return root
    }
    func directory(_ path: String, in root: URL) throws -> URL {
        let url = root.appendingPathComponent(path); try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true); return url
    }
    func testNormalization() {
        for name in ["Vintage Heat", "VintageHeat_Library", "Vintage Heat Library Part 1", "vintageheat", "Vintage-Heat-Library-Part-2", "VINTAGE HEAT", "VintageHeatLibrary"] { XCTAssertEqual(ProductName.key(name), "vintageheat", name) }
    }
    func record(_ name: String, source: MetadataSource = .embedded, version: String = "1") -> RegistrationMetadata { RegistrationMetadata(name: name, version: version, xml: Data(name.utf8), source: source) }
    func testMatchAndOverride() {
        let embedded = record("Vintage Heat"), user = record("VintageHeat", source: .user)
        guard case .matched(let match) = MetadataMatchingService.match("Vintage Heat Library", in: [embedded, user]) else { return XCTFail() }
        XCTAssertEqual(match.source, .user)
        guard case .ambiguous = MetadataMatchingService.match("Vintage Heat", in: [embedded, record("VintageHeat")]) else { return XCTFail() }
        guard case .unresolved = MetadataMatchingService.match("Unknown", in: [embedded]) else { return XCTFail() }
        guard case .matched = MetadataMatchingService.match("Vintage Heat", in: [embedded]) else { return XCTFail() }
    }
    func testXMLParser() throws {
        let records = try MetadataXML.parse(Data("<ProductHints><Product><Name>Test &amp; Heat</Name><ContentVersion>2.3</ContentVersion></Product></ProductHints>".utf8), source: .embedded)
        XCTAssertEqual(records.first?.name, "Test & Heat"); XCTAssertEqual(records.first?.version, "2.3")
        XCTAssertThrowsError(try MetadataXML.parse(Data("<!DOCTYPE x SYSTEM 'file:///etc/passwd'><x/>".utf8), source: .user))
    }
    func testRootsAndWrappers() throws {
        let root = try fixture()
        let a = try directory("Test Library/PAResources/image/Test", in: root)
        try SyntheticArtworkFixture.image(at: a.appendingPathComponent("MST_artwork.png"))
        _ = try directory("OtherLibrary/Samples", in: root)
        _ = try directory("NoSuffix/PAResources", in: root)
        _ = try directory("Scripts/False Library", in: root)
        let found = try LibraryRootDetector.roots(in: root)
        XCTAssertEqual(Set(found.map(\.lastPathComponent)), ["Test Library", "OtherLibrary", "NoSuffix"])
        XCTAssertEqual(try ArtworkService.find(in: root.appendingPathComponent("Test Library"))?.lastPathComponent, "MST_artwork.png")
        let wrapper = try directory("wrapper/Piece.pkg/Payload", in: root)
        _ = try directory("Alpha/Samples", in: wrapper); _ = try directory("Beta/Sounds", in: wrapper)
        XCTAssertEqual(try LibraryRootDetector.roots(in: root.appendingPathComponent("wrapper"), packageName: "Test Library.pkg").count, 2)
        let systemWrapper = try directory("system/Component.pkg/Contents/Payload/Library/Application Support/Native Instruments/Deep Product/PAResources", in: root)
        let deep = try LibraryRootDetector.roots(in: root.appendingPathComponent("system"), packageName: "Deep Product Library.pkg")
        XCTAssertEqual(deep.map(\.lastPathComponent), ["Deep Product"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: systemWrapper.path))
    }
    func testMetadataOnly() throws {
        let root = try fixture(); _ = try directory("Contents/Resources/Service Centre", in: root)
        XCTAssertTrue(try LibraryRootDetector.roots(in: root, packageName: "Expansion Installer.pkg").isEmpty)
    }
    func testCleanupRequiresEveryDependent() {
        let source = SourceArtifact(url: URL(fileURLWithPath: "/tmp/source.iso"), type: .iso)
        var a = ExpansionCandidate(name: "A", sources: [source], payloads: [], destination: URL(fileURLWithPath: "/Users/Shared/A"))
        var b = ExpansionCandidate(name: "B", sources: [source], payloads: [], destination: URL(fileURLWithPath: "/Users/Shared/B"))
        a.state = .installed
        for state in [CandidateState.ready, .failed, .cancelled, .skipped] { b.state = state; XCTAssertFalse(SourceCleanup.eligible(source: source.id, candidates: [a, b])) }
        b.state = .installed; XCTAssertTrue(SourceCleanup.eligible(source: source.id, candidates: [a, b])); XCTAssertFalse(SourceCleanup.eligible(source: UUID(), candidates: [a, b]))
    }
    func testPlannerRejectsUnsafeDestinations() throws {
        let root = try fixture(); let source = try directory("source", in: root)
        for path in ["/", "/Library/Preferences/Evil", "/System/Evil", source.path, source.appendingPathComponent("nested").path] {
            let c = ExpansionCandidate(name: "Test", sources: [], payloads: [source], destination: URL(fileURLWithPath: path))
            XCTAssertThrowsError(try InstallationPlanner.plan(c, mode: .extract), path)
        }
    }
    func testSymlinkRejected() throws {
        let root = try fixture(); let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: URL(fileURLWithPath: "/Library"))
        XCTAssertThrowsError(try SafeTree.validate(link.appendingPathComponent("Preferences")))
    }
    func testVerifiedCopyPreservesSource() async throws {
        let root = try fixture(); let source = try directory("source/Samples", in: root).deletingLastPathComponent()
        let data = Data(repeating: 7, count: 2_100_000); try data.write(to: source.appendingPathComponent("Samples/test.bin"))
        let dest = root.appendingPathComponent("installed")
        let c = ExpansionCandidate(name: "Test", sources: [], payloads: [source], destination: dest, size: Int64(data.count))
        try await InstallationService(log: LoggingService()).execute(InstallationPlanner.plan(c, mode: .extract)) { _ in }
        XCTAssertEqual(try Data(contentsOf: dest.appendingPathComponent("Samples/test.bin")), data)
        XCTAssertEqual(try Data(contentsOf: source.appendingPathComponent("Samples/test.bin")), data)
    }
    func testFailureDoesNotModifyExistingDestination() async throws {
        let root = try fixture(); let source = try directory("source", in: root); let dest = try directory("installed", in: root)
        try Data("old".utf8).write(to: dest.appendingPathComponent("keep"))
        try FileManager.default.createSymbolicLink(at: source.appendingPathComponent("bad"), withDestinationURL: URL(fileURLWithPath: "/etc/passwd"))
        var c = ExpansionCandidate(name: "Test", sources: [], payloads: [source], destination: dest); c.policy = .replace
        do { try await InstallationService(log: LoggingService()).execute(InstallationPlanner.plan(c, mode: .extract)) { _ in }; XCTFail() } catch {}
        XCTAssertEqual(try String(contentsOf: dest.appendingPathComponent("keep"), encoding: .utf8), "old")
    }
    func testMultipartAnalysisOffline() async throws {
        let root = try fixture()
        _ = try directory("Test Library Part 1/Samples", in: root); _ = try directory("Test Library Part 2/Sounds", in: root)
        let xml = try MetadataXML.parse(Data("<ProductHints><Product><Name>Test</Name></Product></ProductHints>".utf8), source: .user)
        let result = try await ExpansionAnalyzer(log: LoggingService()).analyze([root], destination: root.appendingPathComponent("dest"), explicit: xml, offline: true)
        XCTAssertEqual(result.candidates.count, 1); XCTAssertEqual(result.candidates.first?.payloads.count, 2); XCTAssertEqual(result.candidates.first?.metadata?.name, "Test")
    }
    func testLegacyContentPathAndMaschineFiltering() throws {
        let root = try fixture()
        let prefs = try directory("Preferences", in: root)
        let sc = try directory("Service Center", in: root)
        let art = try directory("Images", in: root)
        let expansion = try directory("Expansion Library/Groups", in: root).deletingLastPathComponent()
        try Data("native group fixture".utf8).write(to: expansion.appendingPathComponent("Groups/Test.mxgrp"))
        let kontakt = try directory("Kontakt Library/Instruments", in: root).deletingLastPathComponent()
        let plugin = try directory("Plugin/Presets", in: root).deletingLastPathComponent()
        let volume = try XCTUnwrap(URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeNameKey]).volumeName)
        let hfs = volume + ":" + expansion.path.dropFirst().replacingOccurrences(of: "/", with: ":") + ":"
        for (name, path) in [("Expansion", hfs), ("Kontakt", kontakt.path), ("Plugin", plugin.path)] {
            try PropertyListSerialization.data(fromPropertyList: ["ContentDir": path], format: .xml, options: 0)
                .write(to: prefs.appendingPathComponent("com.native-instruments.\(name).plist"))
        }
        let libraries = try ExistingLibraryService.audit(preferences: prefs, serviceCenter: sc, resources: art, maschineOnly: true)
        XCTAssertEqual(libraries.map(\.name), ["Expansion"])
        let library = try XCTUnwrap(libraries.first)
        XCTAssertEqual(library.content?.standardizedFileURL.path, expansion.standardizedFileURL.path)
        XCTAssertFalse(library.issues.contains(.registration))
        XCTAssertFalse(library.issues.contains(.missingXML))
        XCTAssertEqual(try ExistingLibraryService.audit(preferences: prefs, serviceCenter: sc, resources: art).count, 3)
    }

    func testKontaktInternalGroupsAndFactoryProductsAreNotExpansions() throws {
        let root = try fixture(), prefs = try directory("prefs", in: root), sc = try directory("xml", in: root), images = try directory("images", in: root)
        let records = [("Kontakt 8", "groups/Internal.nkg"), ("Unrelated Instrument", "Sounds/Instrument.nki"), ("Maschine 3", "Groups/Factory.mxgrp"), ("Kontakt Factory Library 2", "Groups/Factory.mxgrp"), ("Real Expansion", "Groups/Kits/Expansion.mxgrp"), ("Legacy Expansion", "Sounds/Old.msnd")]
        for (name, file) in records {
            let content = try directory(name, in: root), preset = content.appendingPathComponent(file)
            try FileManager.default.createDirectory(at: preset.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("synthetic preset".utf8).write(to: preset)
            try PropertyListSerialization.data(fromPropertyList: ["ContentDir": content.path], format: .xml, options: 0).write(to: prefs.appendingPathComponent("com.native-instruments." + name + ".plist"))
            if name == "Maschine 3" {
                let xml = "<ProductHints><Product><Name>Maschine 3</Name><FactoryLibrary><Relevance><Application nativeContent='true'>Maschine</Application></Relevance></FactoryLibrary></Product></ProductHints>"
                try Data(xml.utf8).write(to: sc.appendingPathComponent(name + ".xml"))
            }
        }
        let expansions = try ExistingLibraryService.audit(preferences: prefs, serviceCenter: sc, resources: images, maschineOnly: true)
        XCTAssertEqual(expansions.map(\.name), ["Legacy Expansion", "Real Expansion"])
        XCTAssertEqual(try ExistingLibraryService.audit(preferences: prefs, serviceCenter: sc, resources: images).count, records.count)
    }
    func testUnrelatedXMLCannotMakeAnInstrumentAnExpansion() throws {
        let root = try fixture(), prefs = try directory("prefs", in: root), sc = try directory("xml", in: root), images = try directory("images", in: root)
        try PropertyListSerialization.data(fromPropertyList: ["ContentDir": "/Volumes/Offline/Instrument"], format: .xml, options: 0).write(to: prefs.appendingPathComponent("com.native-instruments.Instrument.plist"))
        let xml = "<ProductHints><Product><Name>Different Expansion</Name><FactoryLibrary><Relevance><Application nativeContent='true'>Maschine</Application></Relevance></FactoryLibrary></Product></ProductHints>"
        try Data(xml.utf8).write(to: sc.appendingPathComponent("Instrument.xml"))
        XCTAssertTrue(try ExistingLibraryService.audit(preferences: prefs, serviceCenter: sc, resources: images, maschineOnly: true).isEmpty)
    }
    func testKnownOfflineCatalogueExpansionSurvivesWithoutServiceCenterXML() throws {
        let root = try fixture(), prefs = try directory("prefs", in: root), sc = try directory("xml", in: root), images = try directory("images", in: root)
        let name = try XCTUnwrap(CatalogueSnapshot.bundled().products.first?.name)
        try PropertyListSerialization.data(fromPropertyList: ["ContentDir": "/Volumes/Offline/" + name], format: .xml, options: 0).write(to: prefs.appendingPathComponent("com.native-instruments." + name + ".plist"))
        XCTAssertEqual(try ExistingLibraryService.audit(preferences: prefs, serviceCenter: sc, resources: images, maschineOnly: true).map(\.name), [name])
    }
    func testOfflineMaschineMetadataAndExternalHFSPath() throws {
        let root = try fixture()
        let prefs = try directory("Preferences", in: root)
        let sc = try directory("Service Center", in: root)
        let art = try directory("Images", in: root)
        for (name, native) in [("Offline Expansion", "true"), ("NKS Plugin", "false")] {
            try PropertyListSerialization.data(fromPropertyList: ["ContentDir": "UnavailableDisk:Libraries:\(name):"], format: .xml, options: 0)
                .write(to: prefs.appendingPathComponent("com.native-instruments.\(name).plist"))
            let xml = "<ProductHints><Product><Name>\(name)</Name><FactoryLibrary><Relevance><Application nativeContent='\(native)'>Maschine</Application></Relevance></FactoryLibrary></Product></ProductHints>"
            try Data(xml.utf8).write(to: sc.appendingPathComponent(name + ".xml"))
        }
        let libraries = try ExistingLibraryService.audit(preferences: prefs, serviceCenter: sc, resources: art, maschineOnly: true)
        XCTAssertEqual(libraries.map(\.name), ["Offline Expansion"])
        XCTAssertEqual(libraries.first?.content?.path, "/Volumes/UnavailableDisk/Libraries/Offline Expansion")
        XCTAssertTrue(try XCTUnwrap(libraries.first).issues.contains(.missingContent))
    }

    func testInstalledMachineAuditWhenRequested() async throws {
        guard ProcessInfo.processInfo.environment["MASCHINE_LIVE_AUDIT"] == "1" else { return }
        let updates = AsyncStream<(InstalledLibrary, Date)>.makeStream()
        let start = Date()
        let libraries = try ExistingLibraryService.audit(maschineOnly: true) {
            updates.continuation.yield(($0, Date()))
        }
        updates.continuation.finish()
        var emitted: [InstalledLibrary] = []
        var first: Date?
        for await (library, time) in updates.stream {
            if first == nil { first = time }
            emitted.append(library)
        }
        print("LIVE AUDIT: \(libraries.count) libraries; first result after \(first?.timeIntervalSince(start) ?? -1)s; total \(Date().timeIntervalSince(start))s")
        XCTAssertFalse(libraries.isEmpty)
        XCTAssertFalse(libraries.contains { ProductName.key($0.name).hasPrefix("kontakt") })
        print("LIVE VERIFIED: Kontakt products excluded from the expansion-only audit")
        XCTAssertEqual(Set(emitted.map(\.id)), Set(libraries.map(\.id)))
    }

    func testLibraryProgressCountsExcludedRegistrationsAndReachesCompletion() async throws {
        let root = try fixture(), prefs = try directory("prefs", in: root), sc = try directory("xml", in: root), images = try directory("images", in: root)
        let expansion = try directory("Expansion/Groups", in: root).deletingLastPathComponent()
        try Data("native preset".utf8).write(to: expansion.appendingPathComponent("Groups/Kit.mxgrp"))
        let kontakt = try directory("Kontakt/groups", in: root).deletingLastPathComponent()
        let plugin = try directory("Plugin/Presets", in: root).deletingLastPathComponent()
        for (name, content) in [("Expansion", expansion), ("Kontakt 8", kontakt), ("Plugin", plugin)] {
            try PropertyListSerialization.data(fromPropertyList: ["ContentDir": content.path], format: .xml, options: 0).write(to: prefs.appendingPathComponent("com.native-instruments." + name + ".plist"))
        }
        try Data().write(to: prefs.appendingPathComponent("unrelated.plist"))
        let progress = AsyncStream<(Int, Int)>.makeStream()
        let libraries = try ExistingLibraryService.audit(preferences: prefs, serviceCenter: sc, resources: images, maschineOnly: true, onProgress: { progress.continuation.yield(($0, $1)) })
        progress.continuation.finish()
        var checked: [Int] = [], totals: [Int] = []
        for await (count, total) in progress.stream { checked.append(count); totals.append(total) }
        XCTAssertEqual(libraries.map(\.name), ["Expansion"])
        XCTAssertEqual(checked, [0, 1, 2, 3])
        XCTAssertEqual(totals, [3, 3, 3, 3])
    }
    func testLibraryAuditCancellationAtLastProgressUpdateDoesNotReportSuccess() async throws {
        let root = try fixture(), prefs = try directory("prefs", in: root)
        try PropertyListSerialization.data(fromPropertyList: ["ContentDir": root.appendingPathComponent("Plugin").path], format: .xml, options: 0).write(to: prefs.appendingPathComponent("com.native-instruments.Plugin.plist"))
        let worker = Task {
            try ExistingLibraryService.audit(preferences: prefs, maschineOnly: true, onProgress: { checked, _ in
                if checked > 0 { withUnsafeCurrentTask { $0?.cancel() } }
            })
        }
        do { _ = try await worker.value; XCTFail("Cancelled scan must not report completion") }
        catch is CancellationError {} catch { XCTFail(error.localizedDescription) }
    }
    func testEmptyLibraryAuditReportsZeroWithoutAnInvalidPercentage() async throws {
        let root = try fixture(), prefs = try directory("prefs", in: root)
        let progress = AsyncStream<(Int, Int)>.makeStream()
        let libraries = try ExistingLibraryService.audit(preferences: prefs, maschineOnly: true, onProgress: { progress.continuation.yield(($0, $1)) })
        progress.continuation.finish()
        var checked: [Int] = [], totals: [Int] = []
        for await (count, total) in progress.stream { checked.append(count); totals.append(total) }
        XCTAssertTrue(libraries.isEmpty); XCTAssertEqual(checked, [0]); XCTAssertEqual(totals, [0])
    }
    func testAuditEmitsLibrariesBeforeReturning() async throws {
        let root = try fixture()
        let prefs = try directory("Preferences", in: root)
        let sc = try directory("Service Center", in: root)
        let images = try directory("Images", in: root)
        let content = try directory("Expansion/Groups", in: root).deletingLastPathComponent()
        try Data("native group fixture".utf8).write(to: content.appendingPathComponent("Groups/Test.mxgrp"))
        try PropertyListSerialization.data(fromPropertyList: ["ContentDir": content.path], format: .xml, options: 0)
            .write(to: prefs.appendingPathComponent("com.native-instruments.Expansion.plist"))
        let updates = AsyncStream<Date>.makeStream()
        let result = try ExistingLibraryService.audit(preferences: prefs, serviceCenter: sc, resources: images, maschineOnly: true) { _ in
            updates.continuation.yield(Date())
        }
        let returned = Date()
        updates.continuation.finish()
        var events = 0
        for await time in updates.stream { events += 1; XCTAssertLessThanOrEqual(time, returned) }
        XCTAssertEqual(events, 1)
        XCTAssertEqual(result.map(\.name), ["Expansion"])
    }

    func testHealthAudit() throws {
        let root = try fixture(); let prefs = try directory("Preferences", in: root), sc = try directory("Service Center", in: root), art = try directory("Images", in: root)
        let content = try directory("Test/PAResources", in: root).deletingLastPathComponent()
        let plist = prefs.appendingPathComponent("com.native-instruments.Test.plist")
        try PropertyListSerialization.data(fromPropertyList: ["ContentDir": content.path, "ContentVersion": "2"], format: .xml, options: 0).write(to: plist)
        var result = try ExistingLibraryService.audit(preferences: prefs, serviceCenter: sc, resources: art)
        XCTAssertEqual(Set(result[0].issues), [.missingArtwork])
        try Data("<ProductHints/>".utf8).write(to: sc.appendingPathComponent("Test.xml"))
        _ = try directory("Test", in: art); try Data([0]).write(to: art.appendingPathComponent("Test/MST_artwork.png"))
        result = try ExistingLibraryService.audit(preferences: prefs, serviceCenter: sc, resources: art); XCTAssertTrue(result[0].issues.isEmpty)
        try FileManager.default.removeItem(at: content)
        result = try ExistingLibraryService.audit(preferences: prefs, serviceCenter: sc, resources: art); XCTAssertTrue(result[0].issues.contains(.missingContent)); XCTAssertTrue(result[0].critical)
    }
}
