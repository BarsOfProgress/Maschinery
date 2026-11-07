import XCTest
import Darwin
@testable import MaschineryCore

final class PermissionRepairTests: XCTestCase {
    func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }; return root
    }
    func expansion(_ root: URL) throws -> URL {
        let folder = root.appendingPathComponent("Test Library"), groups = folder.appendingPathComponent("Groups/Kits")
        try FileManager.default.createDirectory(at: groups, withIntermediateDirectories: true)
        try Data("synthetic Maschine group fixture".utf8).write(to: groups.appendingPathComponent("Test.mxgrp"))
        try SyntheticArtworkFixture.image(at: folder.appendingPathComponent("PAResources/image/Test/MST_artwork.png"))
        let sample = folder.appendingPathComponent("sample.wav")
        try Data("samples".utf8).write(to: sample)
        try FileManager.default.setAttributes([.posixPermissions: 0o200], ofItemAtPath: sample.path)
        return folder
    }
    func mode(_ path: URL) throws -> Int { (try FileManager.default.attributesOfItem(atPath: path.path)[.posixPermissions] as! NSNumber).intValue }
    func engine(_ root: URL, beforeChange: (@Sendable (String) throws -> Void)? = nil) -> PermissionRepairEngine {
        PermissionRepairEngine(root: root.appendingPathComponent("journal"), preferences: root.appendingPathComponent("prefs"), beforeChange: beforeChange)
    }
    @discardableResult func registration(_ root: URL, path: String, filename: String = "Test") throws -> URL {
        let folder = root.appendingPathComponent("prefs")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("com.native-instruments." + filename + ".plist")
        try PropertyListSerialization.data(fromPropertyList: ["ContentDir": path, "ContentVersion": "1.2", "UnrelatedKey": "preserve"], format: .xml, options: 0).write(to: file)
        return file
    }
    func testMissingRegistrationRepairsVerifiedExpansionWithoutCreatingNIRecords() throws {
        let root = try fixture(), folder = try expansion(root), request = try PermissionRepairRequest.capture(product: "Test", content: folder), service = engine(root)
        let attrs = try FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent("sample.wav").path)
        try service.apply(request, user: getuid()); try service.verify(request); try service.finish(request.transaction)
        XCTAssertEqual(try mode(folder.appendingPathComponent("sample.wav")), 0o600)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent("sample.wav").path)[.ownerAccountID] as? NSNumber), attrs[.ownerAccountID] as? NSNumber)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("prefs").path))
        XCTAssertEqual(try service.load(request.transaction)?.phase, .committed)
    }
    func testValidPOSIXAndLegacyHFSRegistrationsRemainByteIdentical() throws {
        let environment = ProcessInfo.processInfo.environment
        if let product = environment["MASCHINERY_PERMISSION_PROBE_PRODUCT"], let path = environment["MASCHINERY_PERMISSION_PROBE_CONTENT"] {
            // Opt-in actual-disk verification is strictly read-only: no engine,
            // chmod, registration writer or transaction store is invoked.
            let request = try PermissionRepairRequest.capture(product: product, content: URL(fileURLWithPath: path))
            let scope = try ExpansionPermissionScope.open(request, preferences: RegistrationLocations.system.preferences, installedProducts: RegistrationLocations.system.installedProducts, user: getuid())
            var info = stat(); XCTAssertEqual(fstat(scope.fd, &info), 0)
            XCTAssertEqual(info.st_ino, request.inode)
            print("READ-ONLY VERIFIED: installed expansion structure and canonical registration identity for " + product)
        }
        let root = try fixture(), folder = try expansion(root), volume = try XCTUnwrap(URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeNameKey]).volumeName)
        let legacy = volume + ":" + folder.path.dropFirst().replacingOccurrences(of: "/", with: ":") + ":"
        for path in [folder.path + "/", legacy] {
            let file = try registration(root, path: path), original = try Data(contentsOf: file)
            let request = try PermissionRepairRequest.capture(product: "Test", content: folder), service = engine(root)
            try service.apply(request, user: getuid()); try service.finish(request.transaction)
            XCTAssertEqual(try Data(contentsOf: file), original)
        }
    }
    func testAbsentContentDirKeyDoesNotNeedFabricatedRegistration() throws {
        let root = try fixture(), folder = try expansion(root), prefs = root.appendingPathComponent("prefs")
        try FileManager.default.createDirectory(at: prefs, withIntermediateDirectories: false)
        let file = prefs.appendingPathComponent("com.native-instruments.Test.plist")
        let original = try PropertyListSerialization.data(fromPropertyList: ["UnrelatedPreference": "keep"], format: .binary, options: 0)
        try original.write(to: file)
        let request = try PermissionRepairRequest.capture(product: "Test", content: folder)
        try engine(root).apply(request, user: getuid())
        XCTAssertEqual(try Data(contentsOf: file), original)
        XCTAssertEqual(try mode(folder.appendingPathComponent("sample.wav")), 0o600)
    }
    func testClientPermissionReceiptRecoversWithoutRegistrationWrites() async throws {
        let root = try fixture(), folder = try expansion(root)
        let paths = RegistrationLocations(preferences: root.appendingPathComponent("prefs"), serviceCenter: root.appendingPathComponent("xml"), images: root.appendingPathComponent("images"), journal: root.appendingPathComponent("engine"))
        let engine = RegistrationEngine(locations: paths), request = try PermissionRepairRequest.capture(product: "Test", content: folder)
        try await engine.repairPermissions(request)
        let client = root.appendingPathComponent("client"), receipts = client.appendingPathComponent("PermissionRepairs")
        try FileManager.default.createDirectory(at: receipts, withIntermediateDirectories: true)
        let file = receipts.appendingPathComponent(request.transaction.uuidString + ".json")
        try JSONEncoder().encode(request).write(to: file)
        try await RepairService(privileged: engine, log: LoggingService(), transactionRoot: client).recover()
        XCTAssertEqual(try mode(folder.appendingPathComponent("sample.wav")), 0o200)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.preferences.path))
        let oldReply = try JSONDecoder().decode(HelperResponse.self, from: Data("{\"phase\":\"absent\"}".utf8))
        XCTAssertNil(oldReply.supportsPermissionRepair)
        XCTAssertEqual(HelperResponse(phase: .absent).supportsPermissionRepair, true)
    }
    func testModernInstalledProductsJSONIsReadOnlyAndConflictsAreRejected() throws {
        let root = try fixture(), folder = try expansion(root), records = root.appendingPathComponent("installed_products")
        try FileManager.default.createDirectory(at: records, withIntermediateDirectories: false)
        let file = records.appendingPathComponent("Test.json")
        let original = try JSONSerialization.data(withJSONObject: ["ContentDir": folder.path, "ContentVersion": "1.0.0"])
        try original.write(to: file)
        let service = PermissionRepairEngine(root: root.appendingPathComponent("journal"), preferences: root.appendingPathComponent("prefs"), installedProducts: records)
        let first = try PermissionRepairRequest.capture(product: "Test", content: folder)
        try service.apply(first, user: getuid()); try service.finish(first.transaction)
        XCTAssertEqual(try Data(contentsOf: file), original)
        let other = root.appendingPathComponent("other")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: false)
        try registration(root, path: other.path)
        let second = try PermissionRepairRequest.capture(product: "Test", content: folder)
        XCTAssertThrowsError(try service.apply(second, user: getuid()))
        XCTAssertEqual(try Data(contentsOf: file), original)
    }
    func testNormalizedProductNamesFindActualRegistrationFilename() throws {
        let root = try fixture(), folder = try expansion(root)
        let file = try registration(root, path: folder.path, filename: "TEST_library"), before = try Data(contentsOf: file)
        let request = try PermissionRepairRequest.capture(product: "Test", content: folder)
        try engine(root).apply(request, user: getuid())
        XCTAssertEqual(try Data(contentsOf: file), before)
    }
    func testMismatchedRegistrationRefusesRepairAndExplainsBothPaths() throws {
        let root = try fixture(), folder = try expansion(root), other = root.appendingPathComponent("Other")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: false)
        let file = try registration(root, path: other.path), before = try Data(contentsOf: file)
        let request = try PermissionRepairRequest.capture(product: "Test", content: folder)
        XCTAssertThrowsError(try engine(root).apply(request, user: getuid())) { error in
            XCTAssertTrue(error.localizedDescription.contains(other.path)); XCTAssertTrue(error.localizedDescription.contains(folder.path))
        }
        XCTAssertEqual(try mode(folder.appendingPathComponent("sample.wav")), 0o200)
        XCTAssertEqual(try Data(contentsOf: file), before)
    }
    func testUnregisteredArbitraryFolderAndIncompleteEvidenceAreRejected() throws {
        let root = try fixture(), folder = try expansion(root)
        try FileManager.default.removeItem(at: folder.appendingPathComponent("PAResources"))
        let request = try PermissionRepairRequest.capture(product: "Test", content: folder)
        XCTAssertThrowsError(try engine(root).apply(request, user: getuid()))
        XCTAssertEqual(try mode(folder.appendingPathComponent("sample.wav")), 0o200)
        let arbitrary = root.appendingPathComponent("Arbitrary Library")
        try FileManager.default.createDirectory(at: arbitrary.appendingPathComponent("PAResources"), withIntermediateDirectories: true)
        let fake = try PermissionRepairRequest.capture(product: "Arbitrary", content: arbitrary)
        XCTAssertThrowsError(try engine(root).apply(fake, user: getuid()))
    }
    func testMatchingRegistrationDoesNotAuthorizeAnArbitraryDirectory() throws {
        let root = try fixture(), folder = root.appendingPathComponent("Test Library")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        try registration(root, path: folder.path)
        let request = try PermissionRepairRequest.capture(product: "Test", content: folder)
        XCTAssertThrowsError(try engine(root).apply(request, user: getuid()))
    }
    func testSymlinkEscapeIncludingHiddenPathsIsRejectedBeforeAnyChanges() throws {
        let root = try fixture(), folder = try expansion(root), outside = root.appendingPathComponent("outside")
        try Data("keep private".utf8).write(to: outside)
        try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: outside.path)
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent(".escape"), withDestinationURL: outside)
        let request = try PermissionRepairRequest.capture(product: "Test", content: folder)
        XCTAssertThrowsError(try engine(root).apply(request, user: getuid()))
        XCTAssertEqual(try mode(outside), 0o400); XCTAssertEqual(try mode(folder.appendingPathComponent("sample.wav")), 0o200)
    }
    func testRootAndAncestorSymlinksAreRejectedDuringCapture() throws {
        let root = try fixture(), folder = try expansion(root), link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: folder)
        XCTAssertThrowsError(try PermissionRepairRequest.capture(product: "Test", content: link))
        let parent = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: parent, withDestinationURL: root)
        XCTAssertThrowsError(try PermissionRepairRequest.capture(product: "Test", content: parent.appendingPathComponent("Test Library")))
    }
    func testHardlinksAndReplacedRootAreRejected() throws {
        let root = try fixture(), folder = try expansion(root)
        let outside = root.appendingPathComponent("outside")
        try Data("private".utf8).write(to: outside)
        try FileManager.default.linkItem(at: outside, to: folder.appendingPathComponent("linked"))
        let request = try PermissionRepairRequest.capture(product: "Test", content: folder)
        XCTAssertThrowsError(try engine(root).apply(request, user: getuid()))
        try FileManager.default.removeItem(at: folder.appendingPathComponent("linked"))
        try FileManager.default.moveItem(at: folder, to: root.appendingPathComponent("previous"))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        XCTAssertThrowsError(try engine(root).apply(request, user: getuid()))
    }
    func testPermissionFailureRollsBackEarlierChangesWithoutRegistrationWrites() throws {
        let root = try fixture(), folder = try expansion(root), last = folder.appendingPathComponent("z.wav")
        try Data("last".utf8).write(to: last)
        try FileManager.default.setAttributes([.posixPermissions: 0o200], ofItemAtPath: last.path)
        let file = try registration(root, path: folder.path), original = try Data(contentsOf: file)
        let request = try PermissionRepairRequest.capture(product: "Test", content: folder)
        let service = engine(root) { path in if path == "z.wav" { throw POSIXError(.EPERM) } }
        XCTAssertThrowsError(try service.apply(request, user: getuid()))
        XCTAssertEqual(try mode(folder.appendingPathComponent("sample.wav")), 0o200)
        XCTAssertEqual(try mode(last), 0o200)
        XCTAssertEqual(try service.load(request.transaction)?.phase, .rolledBack)
        XCTAssertEqual(try Data(contentsOf: file), original)
    }
    func testRestartRollbackWorksAfterRegistrationRemoved() throws {
        let root = try fixture(), folder = try expansion(root), file = try registration(root, path: folder.path)
        let request = try PermissionRepairRequest.capture(product: "Test", content: folder)
        try engine(root).apply(request, user: getuid())
        try FileManager.default.removeItem(at: file)
        try engine(root).rollback(request.transaction)
        XCTAssertEqual(try mode(folder.appendingPathComponent("sample.wav")), 0o200)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }
    func testRepeatedSnapshotsEnumerateCompleteTreeAndRejectOtherOwners() throws {
        let root = try fixture(), folder = try expansion(root), pinned = try SecureDirectory(root: folder, create: false)
        let first = try SharedPermissions.snapshot(pinned), second = try SharedPermissions.snapshot(pinned)
        XCTAssertEqual(first.map(\.path), second.map(\.path)); XCTAssertGreaterThan(first.count, 5)
        var info = stat(); info.st_uid = getuid() + 100_000; info.st_mode = S_IFREG | 0o600
        XCTAssertThrowsError(try ScopedPermissionModes.required(info, user: getuid(), groups: []))
    }
    func testOverlappingRepairAndDifferentCallerAreRejected() throws {
        let root = try fixture(), folder = try expansion(root), service = engine(root)
        let first = try PermissionRepairRequest.capture(product: "Test", content: folder)
        try service.apply(first, user: getuid())
        let second = try PermissionRepairRequest.capture(product: "Test", content: folder)
        XCTAssertThrowsError(try service.apply(second, user: getuid()))
        XCTAssertThrowsError(try service.authorize(first.transaction, user: getuid() + 1))
        try service.rollback(first.transaction)
    }
    func testACLReadDenialProducesDiagnosticWithoutRemovingACL() throws {
        // An execute denial on a regular sample is unrelated to read access
        // and must be preserved rather than blocking a safe read-mode repair.
        let safeRoot = try fixture(), safeFolder = try expansion(safeRoot)
        let executeDeny = Process(); executeDeny.executableURL = URL(fileURLWithPath: "/bin/chmod")
        executeDeny.arguments = ["+a", "everyone deny execute", safeFolder.appendingPathComponent("sample.wav").path]
        executeDeny.standardError = FileHandle.nullDevice
        try executeDeny.run(); executeDeny.waitUntilExit()
        if executeDeny.terminationStatus == 0 {
            let request = try PermissionRepairRequest.capture(product: "Test", content: safeFolder)
            try engine(safeRoot).apply(request, user: getuid())
            XCTAssertEqual(try mode(safeFolder.appendingPathComponent("sample.wav")), 0o600)
        }
        let root = try fixture(), folder = try expansion(root), file = folder.appendingPathComponent("sample.wav")
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/bin/chmod")
        process.arguments = ["+a", "everyone deny read", file.path]
        process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw XCTSkip("Filesystem does not support disposable ACL fixture") }
        let request = try PermissionRepairRequest.capture(product: "Test", content: folder)
        XCTAssertThrowsError(try engine(root).apply(request, user: getuid())) { XCTAssertTrue($0.localizedDescription.contains("ACL")) }
        XCTAssertEqual(try mode(file), 0o200)
    }
    func testLibraryAuditChecksEffectiveAccessRatherThanOwnerModeBitsAlone() throws {
        let root = try fixture(), folder = try expansion(root), sample = folder.appendingPathComponent("sample.wav")
        try registration(root, path: folder.path)
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/bin/chmod")
        process.arguments = ["+a", "everyone allow read", sample.path]; process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw XCTSkip("Filesystem does not support disposable ACL fixture") }
        XCTAssertTrue(FileManager.default.isReadableFile(atPath: sample.path))
        XCTAssertEqual(try mode(sample) & 0o400, 0)
        let libraries = try ExistingLibraryService.audit(preferences: root.appendingPathComponent("prefs"), serviceCenter: root.appendingPathComponent("xml"), resources: root.appendingPathComponent("images"))
        XCTAssertEqual(libraries.count, 1)
        XCTAssertFalse(libraries[0].issues.contains(.unreadable))
    }
    func testHelperProtocolPermissionTransactionNeverCreatesRegistrationDomains() async throws {
        let root = try fixture(), folder = try expansion(root)
        let paths = RegistrationLocations(preferences: root.appendingPathComponent("prefs"), serviceCenter: root.appendingPathComponent("xml"), images: root.appendingPathComponent("images"), journal: root.appendingPathComponent("engine"))
        let engine = RegistrationEngine(locations: paths), request = try PermissionRepairRequest.capture(product: "Test", content: folder)
        try await engine.repairPermissions(request); try await engine.verifyPermissions(request); try await engine.finish(request.transaction)
        let phase = try await engine.phase(request.transaction); XCTAssertEqual(phase, .committed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.preferences.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.serviceCenter.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.images.path))
        do { try await engine.rollback(request.transaction); XCTFail("Committed repair cannot be undone by stale recovery") } catch {}
    }
}
