import XCTest
import Darwin
@testable import MaschineryCore

final class RegisteredTests: XCTestCase {
    func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }; return root
    }
    func locations(_ root: URL) -> RegistrationLocations { RegistrationLocations(preferences: root.appendingPathComponent("prefs"), serviceCenter: root.appendingPathComponent("xml"), images: root.appendingPathComponent("images"), journal: root.appendingPathComponent("journal")) }
    func metadata(_ name: String) -> RegistrationMetadata {
        RegistrationMetadata(name: name, version: "2.7", xml: Data("<ProductHints><Product><Name>\(name)</Name><ContentVersion>2.7</ContentVersion></Product></ProductHints>".utf8), source: .user)
    }
    func payload(_ name: String, in root: URL) throws -> URL {
        let url = root.appendingPathComponent(name + " Library"), art = url.appendingPathComponent("PAResources/image/" + name)
        try FileManager.default.createDirectory(at: art, withIntermediateDirectories: true)
        try Data("art".utf8).write(to: art.appendingPathComponent("MST_artwork.png"))
        try Data("samples".utf8).write(to: url.appendingPathComponent("sample.wav")); return url
    }
    func testUninstallRollbackAndCommitPreserveContentAndOtherProducts() async throws {
        let root = try fixture(), paths = locations(root), engine = RegistrationEngine(locations: paths)
        let content = try payload("Test", in: root)
        let installed = try RegistrationBuilder.build(metadata: metadata("Test"), content: content)
        let other = try RegistrationBuilder.build(metadata: metadata("Other"), content: root.appendingPathComponent("other"))
        try await engine.apply(installed); try await engine.finish(installed.transaction)
        try await engine.apply(other); try await engine.finish(other.transaction)
        let removal = RegistrationRequest(product: "Test", contentPath: content.path, version: "2.7", xml: Data(), resources: [], uninstall: true)
        try await engine.apply(removal); try await engine.verify(removal)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.preferences.appendingPathComponent("com.native-instruments.Test.plist").path))
        try await RegistrationEngine(locations: paths).rollback(removal.transaction)
        try await engine.verify(installed)
        let committedRemoval = RegistrationRequest(product: "Test", contentPath: content.path, version: "2.7", xml: Data(), resources: [], uninstall: true)
        try await engine.apply(committedRemoval); try await engine.finish(committedRemoval.transaction)
        try await engine.verify(committedRemoval); try await engine.verify(other)
        XCTAssertTrue(FileManager.default.fileExists(atPath: content.appendingPathComponent("sample.wav").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.images.appendingPathComponent("Test/MST_artwork.png").path))
        do { try await engine.rollback(committedRemoval.transaction); XCTFail("Committed uninstall cannot roll back") } catch {}
    }
    func testUninstallRejectsStalePathAndLinkedRegistration() async throws {
        let root = try fixture(), paths = locations(root), engine = RegistrationEngine(locations: paths)
        let content = try payload("Test", in: root)
        let installed = try RegistrationBuilder.build(metadata: metadata("Test"), content: content)
        try await engine.apply(installed); try await engine.finish(installed.transaction)
        let stale = RegistrationRequest(product: "Test", contentPath: root.appendingPathComponent("wrong").path, version: "1", xml: Data(), resources: [], uninstall: true)
        do { try await engine.apply(stale); XCTFail("Stale uninstall must fail") } catch {}
        try await engine.verify(installed)
        let xml = paths.serviceCenter.appendingPathComponent("Test.xml")
        let target = root.appendingPathComponent("protected.xml")
        try Data("preserve".utf8).write(to: target)
        try FileManager.default.removeItem(at: xml)
        try FileManager.default.createSymbolicLink(at: xml, withDestinationURL: target)
        let removal = RegistrationRequest(product: "Test", contentPath: content.path, version: "1", xml: Data(), resources: [], uninstall: true)
        do { try await engine.apply(removal); XCTFail("Linked registration must fail") } catch {}
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "preserve")
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.preferences.appendingPathComponent("com.native-instruments.Test.plist").path))
    }
    func testUninstallRefusesTrashOfSharedContentBeforeRemovingRegistration() async throws {
        let root = try fixture(), paths = locations(root), engine = RegistrationEngine(locations: paths)
        let content = try payload("Test", in: root)
        let first = try RegistrationBuilder.build(metadata: metadata("Test"), content: content)
        let second = try RegistrationBuilder.build(metadata: metadata("Other"), content: content)
        try await engine.apply(first); try await engine.finish(first.transaction)
        try await engine.apply(second); try await engine.finish(second.transaction)
        let libraries = try ExistingLibraryService.audit(preferences: paths.preferences, serviceCenter: paths.serviceCenter, resources: paths.images)
        let library = try XCTUnwrap(libraries.first { $0.name == "Test" })
        do {
            try await RepairService(privileged: engine, log: LoggingService()).uninstall(library, trashContent: true)
            XCTFail("Shared content cannot be trashed")
        } catch { XCTAssertTrue(error.localizedDescription.contains("shares this content")) }
        try await engine.verify(first); try await engine.verify(second)
        XCTAssertTrue(FileManager.default.fileExists(atPath: content.appendingPathComponent("sample.wav").path))
    }
    func testOverwriteRegisteredLibraryAndInstallElsewhere() async throws {
        let root = try fixture(), paths = locations(root), engine = RegistrationEngine(locations: paths)
        let old = try payload("Existing", in: root), source = try payload("New", in: root)
        let initial = try RegistrationBuilder.build(metadata: metadata("Test"), content: old)
        try await engine.apply(initial); try await engine.finish(initial.transaction)
        try Data("old-only".utf8).write(to: old.appendingPathComponent("obsolete"))
        var candidate = ExpansionCandidate(name: "Test", sources: [], payloads: [source], destination: old, metadata: metadata("Test"))
        candidate.existingPath = old
        do { _ = try InstallationPlanner.plan(candidate, mode: .install); XCTFail("Ask must block overwrite") } catch {}
        candidate.policy = .replace
        let service = InstallationService(log: LoggingService(), privileged: engine, transactions: TransactionStore(root: root.appendingPathComponent("client")))
        try await service.execute(InstallationPlanner.plan(candidate, mode: .install)) { _ in }
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.appendingPathComponent("obsolete").path))
        candidate.destination = root.appendingPathComponent("elsewhere")
        try await service.execute(InstallationPlanner.plan(candidate, mode: .install)) { _ in }
        XCTAssertTrue(FileManager.default.fileExists(atPath: old.appendingPathComponent("sample.wav").path))
        let data = try Data(contentsOf: paths.preferences.appendingPathComponent("com.native-instruments.Test.plist"))
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String])
        XCTAssertEqual(plist["ContentDir"], candidate.destination.path)
    }
    func testFullInstallPlistXMLArtworkAndSourcePreservation() async throws {
        let root = try fixture(), source = try payload("Test", in: root), paths = locations(root)
        let engine = RegistrationEngine(locations: paths), destination = root.appendingPathComponent("installed")
        let candidate = ExpansionCandidate(name: "Test", sources: [], payloads: [source], destination: destination, metadata: metadata("Test"))
        try await InstallationService(log: LoggingService(), privileged: engine, transactions: TransactionStore(root: root.appendingPathComponent("client"))).execute(InstallationPlanner.plan(candidate, mode: .install)) { _ in }
        let data = try Data(contentsOf: paths.preferences.appendingPathComponent("com.native-instruments.Test.plist"))
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String])
        XCTAssertEqual(plist["ContentDir"], destination.path); XCTAssertEqual(plist["ContentVersion"], "2.7")
        XCTAssertEqual(try Data(contentsOf: paths.serviceCenter.appendingPathComponent("Test.xml")), metadata("Test").xml)
        XCTAssertEqual(try String(contentsOf: paths.images.appendingPathComponent("Test/MST_artwork.png"), encoding: .utf8), "art")
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.appendingPathComponent("sample.wav").path))
    }
    func testBulkFortyMultipartExpansionsOffline() async throws {
        let root = try fixture(), paths = locations(root), engine = RegistrationEngine(locations: paths)
        let service = InstallationService(log: LoggingService(), privileged: engine, transactions: TransactionStore(root: root.appendingPathComponent("client")))
        let input = root.appendingPathComponent("input"); try FileManager.default.createDirectory(at: input, withIntermediateDirectories: false)
        var records: [RegistrationMetadata] = []
        for n in 0..<40 {
            let name = "Expansion \(n)"; records.append(metadata(name))
            let first = try payload(name + " Library Part 1", in: input)
            // Normalize fixture folder names to the two real-world part variants.
            try FileManager.default.moveItem(at: first, to: input.appendingPathComponent(name + " Library Part 1"))
            let second = input.appendingPathComponent(name + " Library Part 2")
            try FileManager.default.createDirectory(at: second, withIntermediateDirectories: false)
            try Data("part two".utf8).write(to: second.appendingPathComponent("second.wav"))
        }
        let analysis = try await ExpansionAnalyzer(log: LoggingService()).analyze([input], destination: root.appendingPathComponent("output"), explicit: records, offline: true)
        XCTAssertEqual(analysis.candidates.count, 40)
        for candidate in analysis.candidates {
            XCTAssertEqual(candidate.payloads.count, 2)
            try await service.execute(InstallationPlanner.plan(candidate, mode: .install)) { _ in }
            XCTAssertTrue(FileManager.default.fileExists(atPath: candidate.destination.appendingPathComponent("second.wav").path))
        }
        XCTAssertEqual(try SafeTree.children(paths.serviceCenter).count, 40)
    }
    func testRegistrationFailureRestoresContentAndRegistration() async throws {
        let root = try fixture(), paths = locations(root), engine = RegistrationEngine(locations: paths)
        let source = try payload("Test", in: root), dest = root.appendingPathComponent("installed")
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: false)
        try Data("old content".utf8).write(to: dest.appendingPathComponent("keep"))
        let old = try RegistrationBuilder.build(metadata: metadata("Test"), content: dest)
        try await engine.apply(old); try await engine.finish(old.transaction)
        var candidate = ExpansionCandidate(name: "Test", sources: [], payloads: [source], destination: dest, metadata: metadata("Test")); candidate.policy = .replace
        let failing = VerificationFailure(base: engine)
        do { try await InstallationService(log: LoggingService(), privileged: failing, transactions: TransactionStore(root: root.appendingPathComponent("client"))).execute(InstallationPlanner.plan(candidate, mode: .install)) { _ in }; XCTFail("Expected verification failure") } catch {}
        XCTAssertEqual(try String(contentsOf: dest.appendingPathComponent("keep"), encoding: .utf8), "old content")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dest.appendingPathComponent("sample.wav").path))
        try await engine.verify(old)
    }
    func testRegistrationUndoSurvivesEngineRestart() async throws {
        let root = try fixture(), paths = locations(root), content = try payload("Test", in: root)
        let request = try RegistrationBuilder.build(metadata: metadata("Test"), content: content)
        try await RegistrationEngine(locations: paths).apply(request)
        let restarted = RegistrationEngine(locations: paths)
        try await restarted.rollback(request.transaction)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.preferences.appendingPathComponent("com.native-instruments.Test.plist").path))
        let phase = try await restarted.phase(request.transaction); XCTAssertEqual(phase, .rolledBack)
    }
    func testSecurityRejectsTraversalSymlinksHardlinksAndMismatchedXML() async throws {
        let root = try fixture(), paths = locations(root), engine = RegistrationEngine(locations: paths)
        let source = try payload("Test", in: root)
        for name in ["../Evil", "A/B", "A\\B", "..", " Test", "Test\n"] { XCTAssertThrowsError(try RegistrationValidation.product(name)) }
        for path in ["../evil", "/etc/passwd", "a/../../b", "a//b"] { XCTAssertThrowsError(try RegistrationValidation.relative(path)) }
        let bad = RegistrationRequest(product: "Other", contentPath: source.path, version: "1", xml: metadata("Test").xml, resources: [])
        do { try await engine.apply(bad); XCTFail() } catch {}
        try FileManager.default.createDirectory(at: paths.preferences, withIntermediateDirectories: true)
        let target = paths.preferences.appendingPathComponent("com.native-instruments.Test.plist"), outside = root.appendingPathComponent("outside")
        try Data("untouched".utf8).write(to: outside)
        let request = try RegistrationBuilder.build(metadata: metadata("Test"), content: source)
        try FileManager.default.createSymbolicLink(at: target, withDestinationURL: outside)
        do { try await engine.apply(request); XCTFail() } catch {}
        XCTAssertEqual(try String(contentsOf: outside, encoding: .utf8), "untouched")
        try FileManager.default.removeItem(at: target); try FileManager.default.linkItem(at: outside, to: target)
        do { try await engine.apply(request); XCTFail() } catch {}
        XCTAssertEqual(try String(contentsOf: outside, encoding: .utf8), "untouched")
    }
    func testMergePreservesUnrelatedAndReplaceIsExplicit() async throws {
        let root = try fixture(), source = try payload("Test", in: root), dest = root.appendingPathComponent("dest")
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: false); try Data("keep".utf8).write(to: dest.appendingPathComponent("unrelated"))
        var c = ExpansionCandidate(name: "Test", sources: [], payloads: [source], destination: dest)
        XCTAssertThrowsError(try InstallationPlanner.plan(c, mode: .extract))
        c.policy = .merge
        let service = InstallationService(log: LoggingService(), transactions: TransactionStore(root: root.appendingPathComponent("client")))
        try await service.execute(InstallationPlanner.plan(c, mode: .extract)) { _ in }
        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.appendingPathComponent("unrelated").path))
        c.policy = .replace; try await service.execute(InstallationPlanner.plan(c, mode: .extract)) { _ in }
        XCTAssertFalse(FileManager.default.fileExists(atPath: dest.appendingPathComponent("unrelated").path))
    }
    func testRepairAndRelocate() async throws {
        let root = try fixture(), paths = locations(root), engine = RegistrationEngine(locations: paths), source = try payload("Test", in: root)
        let initial = try RegistrationBuilder.build(metadata: metadata("Test"), content: source)
        try await engine.apply(initial); try await engine.finish(initial.transaction)
        try FileManager.default.removeItem(at: paths.serviceCenter.appendingPathComponent("Test.xml"))
        try FileManager.default.removeItem(at: paths.images.appendingPathComponent("Test/MST_artwork.png"))
        let library = try XCTUnwrap(ExistingLibraryService.audit(preferences: paths.preferences, serviceCenter: paths.serviceCenter, resources: paths.images).first)
        XCTAssertFalse(library.issues.contains(.missingXML)); XCTAssertTrue(library.issues.contains(.missingArtwork))
        let service = RepairService(privileged: engine, log: LoggingService())
        let plan = try await service.plan(library, explicit: [metadata("Test")], hints: ProductHintsService(), offline: true)
        try await service.execute(plan)
        XCTAssertTrue(try ExistingLibraryService.audit(preferences: paths.preferences, serviceCenter: paths.serviceCenter, resources: paths.images)[0].issues.isEmpty)
        let destination = root.appendingPathComponent("Relocated Test")
        try await RelocationService(privileged: engine, log: LoggingService()).relocate(plan, destination: destination, trashOld: false) { _ in }
        let relocated = try ExistingLibraryService.audit(preferences: paths.preferences, serviceCenter: paths.serviceCenter, resources: paths.images)[0]
        XCTAssertEqual(relocated.content?.path, destination.path); XCTAssertTrue(relocated.issues.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }
    func testPermissionRepairIsSelectiveAndVerified() async throws {
        let root = try fixture(), paths = locations(root), engine = RegistrationEngine(locations: paths), source = try payload("Test", in: root)
        let groups = source.appendingPathComponent("Groups")
        try FileManager.default.createDirectory(at: groups, withIntermediateDirectories: false)
        try Data("synthetic native preset".utf8).write(to: groups.appendingPathComponent("Test.mxgrp"))
        let initial = try RegistrationBuilder.build(metadata: metadata("Test"), content: source)
        try await engine.apply(initial); try await engine.finish(initial.transaction)
        let sample = source.appendingPathComponent("sample.wav")
        try FileManager.default.setAttributes([.posixPermissions: 0o200], ofItemAtPath: sample.path)
        let unrelated = root.appendingPathComponent("unrelated"); try Data("keep".utf8).write(to: unrelated)
        try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: unrelated.path)
        let library = try ExistingLibraryService.audit(preferences: paths.preferences, serviceCenter: paths.serviceCenter, resources: paths.images)[0]
        XCTAssertTrue(library.issues.contains(.unreadable))
        let service = RepairService(privileged: engine, log: LoggingService(), transactionRoot: root.appendingPathComponent("client"))
        let originalRegistration = try Data(contentsOf: paths.preferences.appendingPathComponent("com.native-instruments.Test.plist"))
        let plan = try service.permissionPlan(library)
        XCTAssertNil(plan.request)
        XCTAssertNotNil(plan.permissions)
        try await service.execute(plan)
        XCTAssertEqual(try String(contentsOf: sample, encoding: .utf8), "samples")
        XCTAssertEqual(try Data(contentsOf: paths.preferences.appendingPathComponent("com.native-instruments.Test.plist")), originalRegistration)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: unrelated.path)[.posixPermissions] as? NSNumber)?.intValue, 0o400)
    }
    func testBrokenRegistrationCanLocateContent() async throws {
        let root = try fixture(), paths = locations(root), engine = RegistrationEngine(locations: paths), source = try payload("Test", in: root)
        try FileManager.default.createDirectory(at: paths.preferences, withIntermediateDirectories: true)
        try Data("invalid plist".utf8).write(to: paths.preferences.appendingPathComponent("com.native-instruments.Test.plist"))
        let library = try ExistingLibraryService.audit(preferences: paths.preferences, serviceCenter: paths.serviceCenter, resources: paths.images)[0]
        XCTAssertTrue(library.issues.contains(.registration))
        let service = RepairService(privileged: engine, log: LoggingService())
        let plan = try await service.plan(library, content: source, explicit: [metadata("Test")], hints: ProductHintsService(), offline: true)
        try await service.execute(plan)
        XCTAssertTrue(try ExistingLibraryService.audit(preferences: paths.preferences, serviceCenter: paths.serviceCenter, resources: paths.images)[0].issues.isEmpty)
    }
    func testLostCommitReplyKeepsVerifiedInstallation() async throws {
        let root = try fixture(), paths = locations(root), engine = RegistrationEngine(locations: paths), source = try payload("Test", in: root), dest = root.appendingPathComponent("dest")
        let service = InstallationService(log: LoggingService(), privileged: LostFinishReply(base: engine), transactions: TransactionStore(root: root.appendingPathComponent("client")))
        let c = ExpansionCandidate(name: "Test", sources: [], payloads: [source], destination: dest, metadata: metadata("Test"))
        try await service.execute(InstallationPlanner.plan(c, mode: .install)) { _ in }
        XCTAssertEqual(try String(contentsOf: dest.appendingPathComponent("sample.wav"), encoding: .utf8), "samples")
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.serviceCenter.appendingPathComponent("Test.xml").path))
        try await service.transactions.recover(using: engine, log: LoggingService())
        XCTAssertTrue(try service.transactions.records().isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.path))
    }
    func testCancellationAfterRegistrationRollsBack() async throws {
        let root = try fixture(), paths = locations(root), engine = RegistrationEngine(locations: paths), source = try payload("Test", in: root), dest = root.appendingPathComponent("dest")
        let service = InstallationService(log: LoggingService(), privileged: CancelAfterApply(base: engine), transactions: TransactionStore(root: root.appendingPathComponent("client")))
        let c = ExpansionCandidate(name: "Test", sources: [], payloads: [source], destination: dest, metadata: metadata("Test"))
        let task = Task { try await service.execute(InstallationPlanner.plan(c, mode: .install)) { _ in } }
        do { try await task.value; XCTFail("Expected cancellation") } catch is CancellationError {} catch { XCTFail(error.localizedDescription) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: dest.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.serviceCenter.appendingPathComponent("Test.xml").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }
    func testScopedPermissionSnapshotApplyAndRollback() throws {
        let root = try fixture(), library = try payload("Test", in: root), file = library.appendingPathComponent("sample.wav")
        try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: file.path)
        let pinned = try SecureDirectory(root: library, create: false)
        let snapshot = try SharedPermissions.snapshot(pinned)
        try SharedPermissions.set(snapshot, root: pinned, restore: false)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue, 0o444)
        try SharedPermissions.set(snapshot, root: pinned, restore: true)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue, 0o400)
    }
    func testPrivilegedReplacementRequiresExistingLibraryEvidence() throws {
        let root = try fixture(), directory = root.appendingPathComponent("Existing"), preferences = root.appendingPathComponent("Preferences")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let pinned = try SecureDirectory(root: directory, create: false), prefs = try SecureDirectory(root: preferences)
        XCTAssertThrowsError(try SharedContentOperations.validateExisting(pinned, product: "Test", destination: directory.path, preferences: prefs))
        try prefs.write("com.native-instruments.Test.plist", data: PropertyListSerialization.data(fromPropertyList: ["ContentDir": directory.path], format: .xml, options: 0))
        XCTAssertNoThrow(try SharedContentOperations.validateExisting(pinned, product: "Test", destination: directory.path, preferences: prefs))
        try prefs.remove("com.native-instruments.Test.plist")
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("PAResources"), withIntermediateDirectories: false)
        XCTAssertNoThrow(try SharedContentOperations.validateExisting(pinned, product: "Test", destination: directory.path, preferences: prefs))
    }
    func testPrivilegedPayloadRejectsArbitraryLocations() throws {
        let root = try fixture()
        let request = SharedContentRequest(transaction: UUID(), product: "Test", destination: root.appendingPathComponent("Test").path)
        XCTAssertThrowsError(try SharedContentOperations.swap(request, user: getuid()))
        XCTAssertThrowsError(try SharedContentOperations.restore(request, user: getuid()))
        XCTAssertThrowsError(try SharedContentOperations.cleanup(request, user: getuid()))
        let reserved = SharedContentRequest(transaction: UUID(), product: "NI Resources", destination: "/Users/Shared/NI Resources")
        XCTAssertThrowsError(try SharedContentOperations.swap(reserved, user: getuid()))
    }
    func testAutomaticProductHintsFeedsFullInstall() async throws {
        let root = try fixture(), source = try payload("Test", in: root), locations = locations(root)
        let transport = HintsTransport(data: metadata("Test").xml)
        let hints = ProductHintsService { try await transport.fetch() }
        let analysis = try await ExpansionAnalyzer(log: LoggingService(), hints: hints).analyze([source], destination: root.appendingPathComponent("dest"), offline: false)
        let candidate = try XCTUnwrap(analysis.candidates.first)
        XCTAssertEqual(candidate.metadata?.source, .productHints)
        let engine = RegistrationEngine(locations: locations)
        try await InstallationService(log: LoggingService(), privileged: engine, transactions: TransactionStore(root: root.appendingPathComponent("client"))).execute(InstallationPlanner.plan(candidate, mode: .install)) { _ in }
        XCTAssertEqual(try MetadataXML.read(locations.serviceCenter.appendingPathComponent("Test.xml"), source: .embedded).first?.name, "Test")
        let calls = await transport.calls; XCTAssertEqual(calls, 1)
    }
    func testOfflineProductHintsMakesNoRequestAndBatchSharesCache() async throws {
        let transport = HintsTransport(data: metadata("Test").xml)
        let hints = ProductHintsService { try await transport.fetch() }
        let offline = try await hints.records(offline: true)
        XCTAssertTrue(offline.isEmpty)
        var calls = await transport.calls; XCTAssertEqual(calls, 0)
        async let first = hints.records(offline: false)
        async let second = hints.records(offline: false)
        let results = try await (first, second)
        XCTAssertEqual(results.0.first?.name, "Test"); XCTAssertEqual(results.1.first?.name, "Test")
        _ = try await hints.records(offline: false)
        calls = await transport.calls; XCTAssertEqual(calls, 1)
    }
    func testSharedSourceCleanupRequiresAllVerifiedAndSelected() {
        let source = SourceArtifact(url: URL(fileURLWithPath: "/Users/Shared/Test.iso"), type: .iso)
        var a = ExpansionCandidate(name: "A", sources: [source], payloads: [], destination: URL(fileURLWithPath: "/Users/Shared/A"))
        var b = ExpansionCandidate(name: "B", sources: [source], payloads: [], destination: URL(fileURLWithPath: "/Users/Shared/B"))
        a.state = .installed; b.state = .failed
        XCTAssertTrue(SourceTrashService.eligibleSources(candidates: [a,b], selected: [a.id,b.id]).isEmpty)
        b.state = .installed
        XCTAssertTrue(SourceTrashService.eligibleSources(candidates: [a,b], selected: [a.id]).isEmpty)
        XCTAssertEqual(SourceTrashService.eligibleSources(candidates: [a,b], selected: [a.id,b.id]).count, 1)
        b.state = .extracted
        XCTAssertTrue(SourceTrashService.eligibleSources(candidates: [a,b], selected: [a.id,b.id]).isEmpty)
    }
}
private struct VerificationFailure: PrivilegedService {
    let base: RegistrationEngine
    func preflight() async throws { try await base.preflight() }
    func apply(_ request: RegistrationRequest) async throws { try await base.apply(request) }
    func verify(_ request: RegistrationRequest) async throws { throw MaschineryError.invalid("Injected final verification failure") }
    func finish(_ id: UUID) async throws { try await base.finish(id) }
    func rollback(_ id: UUID) async throws { try await base.rollback(id) }
    func phase(_ id: UUID) async throws -> RegistrationPhase { try await base.phase(id) }
}

private struct LostFinishReply: PrivilegedService {
    let base: RegistrationEngine
    func preflight() async throws { try await base.preflight() }
    func apply(_ request: RegistrationRequest) async throws { try await base.apply(request) }
    func verify(_ request: RegistrationRequest) async throws { try await base.verify(request) }
    func finish(_ id: UUID) async throws { try await base.finish(id); throw MaschineryError.unavailable("Injected lost reply after commit") }
    func rollback(_ id: UUID) async throws { try await base.rollback(id) }
    func phase(_ id: UUID) async throws -> RegistrationPhase { try await base.phase(id) }
}
private struct CancelAfterApply: PrivilegedService {
    let base: RegistrationEngine
    func preflight() async throws { try await base.preflight() }
    func apply(_ request: RegistrationRequest) async throws { try await base.apply(request); withUnsafeCurrentTask { $0?.cancel() } }
    func verify(_ request: RegistrationRequest) async throws { try await base.verify(request) }
    func finish(_ id: UUID) async throws { try await base.finish(id) }
    func rollback(_ id: UUID) async throws { try await base.rollback(id) }
    func phase(_ id: UUID) async throws -> RegistrationPhase { try await base.phase(id) }
}

private actor HintsTransport {
    let data: Data
    var calls = 0
    init(data: Data) { self.data = data }
    func fetch() async throws -> Data { calls += 1; try await Task.sleep(for: .milliseconds(30)); return data }
}
