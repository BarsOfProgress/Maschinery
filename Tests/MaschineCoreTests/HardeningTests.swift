import XCTest
@testable import MaschineCore

final class HardeningTests: XCTestCase {
    func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }; return root
    }
    func testSafeArchiveRejectsSymlinkBeforeItCanEscape() async throws {
        let root = try fixture(), input = root.appendingPathComponent("input"), output = root.appendingPathComponent("output")
        try FileManager.default.createDirectory(at: input, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: input.appendingPathComponent("escape"), withDestinationURL: root)
        let archive = root.appendingPathComponent("bad.tar.gz")
        let result = try await ProcessRunner().run("/usr/bin/tar", ["-czf", archive.path, "-C", input.path, "."])
        XCTAssertEqual(result.code, 0)
        XCTAssertThrowsError(try ArchiveExtraction.extract(archive, into: output))
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.appendingPathComponent("escape").path))
    }
    func testPKGFailureUsesSafeXARAndExpandsCompressedPayload() async throws {
        let root = try fixture(), input = root.appendingPathComponent("input"), workspace = root.appendingPathComponent("workspace")
        try FileManager.default.createDirectory(at: input.appendingPathComponent("Fallback Library/Samples"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: false)
        try Data("sample".utf8).write(to: input.appendingPathComponent("Fallback Library/Samples/test.wav"))
        let package = root.appendingPathComponent("Fallback Library.pkg")
        let made = try await ProcessRunner().run("/usr/bin/pkgbuild", ["--root", input.path, "--identifier", "test.fallback", "--version", "1.0", package.path])
        XCTAssertEqual(made.code, 0, made.stderr)
        let log = LoggingService()
        let result = try await PackageExtractionService(runner: FailPkgutil(), log: log).expand(package, workspace: workspace)
        let roots = try LibraryRootDetector.roots(in: result, packageName: package.lastPathComponent)
        XCTAssertEqual(roots.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: roots[0].appendingPathComponent("Samples/test.wav").path))
        let logs = await log.snapshot(); XCTAssertTrue(logs.contains { $0.message.contains("fallback") || $0.message.contains("xar") })
    }
    func testBundlePackageWithCompressedArchive() async throws {
        let root = try fixture(), input = root.appendingPathComponent("input"), bundle = root.appendingPathComponent("Bundle Library.pkg"), workspace = root.appendingPathComponent("workspace")
        try FileManager.default.createDirectory(at: input.appendingPathComponent("Bundle/PAResources"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bundle.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: false)
        try Data("sample".utf8).write(to: input.appendingPathComponent("Bundle/sample.wav"))
        let tar = try await ProcessRunner().run("/usr/bin/tar", ["-czf", bundle.appendingPathComponent("Contents/Archive.pax.gz").path, "-C", input.path, "."])
        XCTAssertEqual(tar.code, 0, tar.stderr)
        let result = try await PackageExtractionService(runner: FailPkgutil(), log: LoggingService()).expand(bundle, workspace: workspace)
        let roots = try LibraryRootDetector.roots(in: result, packageName: bundle.lastPathComponent)
        XCTAssertEqual(roots.count, 1); XCTAssertEqual(roots[0].lastPathComponent, "Bundle")
        XCTAssertTrue(FileManager.default.fileExists(atPath: roots[0].appendingPathComponent("sample.wav").path))
    }
    func testRealReadOnlyISOWithLooseLibraryAndMetadata() async throws {
        let root = try fixture(), input = root.appendingPathComponent("image-input"), image = root.appendingPathComponent("Synthetic.iso")
        try FileManager.default.createDirectory(at: input.appendingPathComponent("ISO Test Library/PAResources"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: input.appendingPathComponent("Service Centre"), withIntermediateDirectories: false)
        try Data("sample".utf8).write(to: input.appendingPathComponent("ISO Test Library/sample.wav"))
        try Data("<ProductHints><Product><Name>ISO Test</Name></Product></ProductHints>".utf8).write(to: input.appendingPathComponent("Service Centre/ISO Test.xml"))
        let made = try await ProcessRunner().run("/usr/bin/hdiutil", ["makehybrid", "-iso", "-joliet", "-o", image.path, input.path])
        if made.code != 0 && made.stderr.localizedCaseInsensitiveContains("not permitted") { throw XCTSkip("Host sandbox denied disk image creation: " + made.stderr) }
        XCTAssertEqual(made.code, 0, made.stderr)
        let service = ISOService()
        let mounts: [URL]
        do { mounts = try await service.attach(image) }
        catch {
            let detail = error.localizedDescription
            if detail.localizedCaseInsensitiveContains("not permitted") || detail.localizedCaseInsensitiveContains("device not configured") { throw XCTSkip("Host cannot attach disk images: " + detail) }
            throw error
        }
        XCTAssertFalse(mounts.isEmpty)
        for mount in mounts { try await service.detach(mount) }
        let analysis = try await ExpansionAnalyzer(log: LoggingService()).analyze([image], destination: root.appendingPathComponent("output"), offline: true)
        XCTAssertEqual(analysis.candidates.count, 1)
        XCTAssertEqual(analysis.candidates.first?.metadata?.name, "ISO Test")
        XCTAssertTrue(FileManager.default.fileExists(atPath: image.path))
    }
    func testMultipartISOWithMetadataInDifferentPKGAndLooseLibrary() async throws {
        let root = try fixture(), components = root.appendingPathComponent("components")
        try FileManager.default.createDirectory(at: components, withIntermediateDirectories: false)
        for part in 1...2 {
            let payload = root.appendingPathComponent("payload-\(part)")
            try FileManager.default.createDirectory(at: payload.appendingPathComponent("Test Library Part \(part)"), withIntermediateDirectories: true)
            try Data("part \(part)".utf8).write(to: payload.appendingPathComponent("Test Library Part \(part)/part-\(part).wav"))
            let built = try await ProcessRunner().run("/usr/bin/pkgbuild", ["--root", payload.path, "--identifier", "test.part\(part)", "--version", "1", components.appendingPathComponent("Test Library Part \(part).pkg").path])
            XCTAssertEqual(built.code, 0, built.stderr)
        }
        let metadata = root.appendingPathComponent("metadata/Library/Application Support/Native Instruments/Service Centre")
        try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: true)
        for name in ["Test", "Loose"] { try Data("<ProductHints><Product><Name>\(name)</Name></Product></ProductHints>".utf8).write(to: metadata.appendingPathComponent(name + ".xml")) }
        let built = try await ProcessRunner().run("/usr/bin/pkgbuild", ["--root", root.appendingPathComponent("metadata").path, "--identifier", "test.installer", "--version", "1", components.appendingPathComponent("Expansion Installer.pkg").path])
        XCTAssertEqual(built.code, 0, built.stderr)
        try FileManager.default.createDirectory(at: components.appendingPathComponent("Loose Library/PAResources"), withIntermediateDirectories: true)
        try Data("loose".utf8).write(to: components.appendingPathComponent("Loose Library/sample.wav"))
        let image = root.appendingPathComponent("synthetic.iso"); try Data().write(to: image)
        let runner = MockMountRunner(fixtures: components)
        let result = try await ExpansionAnalyzer(log: LoggingService(), runner: runner).analyze([image], destination: root.appendingPathComponent("dest"), offline: true)
        XCTAssertEqual(result.candidates.count, 2)
        XCTAssertEqual(result.candidates.first(where: { $0.name == "Test" })?.payloads.count, 2)
        XCTAssertEqual(result.candidates.first(where: { $0.name == "Test" })?.metadata?.name, "Test")
        XCTAssertEqual(result.candidates.first(where: { $0.name == "Loose" })?.metadata?.name, "Loose")
        let active = await runner.active; XCTAssertNil(active)
        XCTAssertTrue(FileManager.default.fileExists(atPath: image.path))
    }
    func testCancelledMountIsDetached() async throws {
        let runner = MockMountRunner()
        let service = ISOService(runner: runner)
        let task = Task { try await service.attach(URL(fileURLWithPath: "/Users/Shared/synthetic.iso")) }
        try await Task.sleep(for: .milliseconds(30)); task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") } catch is CancellationError {} catch { XCTFail(error.localizedDescription) }
        let active = await runner.active, detached = await runner.detached
        XCTAssertNil(active); XCTAssertTrue(detached)
    }
    func testCrashRecoveryRestoresContentAndRegistration() async throws {
        let root = try fixture(), dest = root.appendingPathComponent("destination"), id = UUID()
        let workspace = root.appendingPathComponent(".maschine-" + id.uuidString), backup = workspace.appendingPathComponent("previous")
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: false)
        try Data("old".utf8).write(to: backup.appendingPathComponent("data")); try Data("new".utf8).write(to: dest.appendingPathComponent("data"))
        let locations = RegistrationLocations(preferences: root.appendingPathComponent("prefs"), serviceCenter: root.appendingPathComponent("xml"), images: root.appendingPathComponent("images"), journal: root.appendingPathComponent("helper-journal"))
        let engine = RegistrationEngine(locations: locations)
        let request = RegistrationRequest(transaction: id, product: "Test", contentPath: dest.path, version: "1", xml: Data("<ProductHints><Product><Name>Test</Name></Product></ProductHints>".utf8), resources: [])
        try await engine.apply(request)
        let store = TransactionStore(root: root.appendingPathComponent("client"))
        try store.save(ContentJournal(id: id, destination: dest, workspace: workspace, hadDestination: true, registered: true, phase: .contentReady))
        try await store.recover(using: engine, log: LoggingService())
        XCTAssertEqual(try String(contentsOf: dest.appendingPathComponent("data"), encoding: .utf8), "old")
        XCTAssertFalse(FileManager.default.fileExists(atPath: locations.preferences.appendingPathComponent("com.native-instruments.Test.plist").path))
        XCTAssertTrue(try store.records().isEmpty)
    }
    func testChangedSourceCannotBeTrashed() throws {
        let root = try fixture(), file = root.appendingPathComponent("source.iso")
        try Data("first".utf8).write(to: file)
        let source = SourceArtifact(url: file, type: .iso)
        try Data("changed".utf8).write(to: file)
        XCTAssertThrowsError(try SourceTrashService.trash(source))
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }
    func testNativeTrashAndRestoreOfDisposableSource() throws {
        let root = try fixture(), file = root.appendingPathComponent("MaschineMachine-Test-" + UUID().uuidString + ".iso")
        try Data("disposable synthetic source".utf8).write(to: file)
        let artifact = SourceArtifact(url: file, type: .iso)
        let trashed = try XCTUnwrap(SourceTrashService.trash(artifact))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: trashed.path))
        // Restore only this uniquely named test file so tests do not leave content in the user's Trash.
        try FileManager.default.moveItem(at: trashed, to: file)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "disposable synthetic source")
    }
    func testDiscoveryFailureDoesNotDiscardIndependentExpansion() async throws {
        let root = try fixture(), good = root.appendingPathComponent("Good Library")
        try FileManager.default.createDirectory(at: good, withIntermediateDirectories: false)
        try Data("sample".utf8).write(to: good.appendingPathComponent("sample.wav"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("Bad Library"), withDestinationURL: URL(fileURLWithPath: "/Library"))
        let result = try await ExpansionAnalyzer(log: LoggingService()).analyze([root], destination: root.appendingPathComponent("out"), offline: true)
        XCTAssertEqual(result.candidates.count, 2)
        XCTAssertEqual(result.candidates.filter { $0.state == .failed }.count, 1)
        XCTAssertEqual(result.candidates.first(where: { $0.name == "Good" })?.payloads.count, 1)
    }
    func testAdHocHelperFailsBeforeChangingContent() async throws {
        let root = try fixture(), source = root.appendingPathComponent("Test Library"), dest = root.appendingPathComponent("destination")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        try Data("source".utf8).write(to: source.appendingPathComponent("data"))
        let metadata = RegistrationMetadata(name: "Test", xml: Data("<ProductHints><Product><Name>Test</Name></Product></ProductHints>".utf8), source: .user)
        let c = ExpansionCandidate(name: "Test", sources: [], payloads: [source], destination: dest, metadata: metadata)
        do { try await InstallationService(log: LoggingService()).execute(InstallationPlanner.plan(c, mode: .install)) { _ in }; XCTFail("Tests must not access a real helper") } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: dest.path))
    }
}
private struct FailPkgutil: ProcessRunning {
    func run(_ executable: String, _ arguments: [String]) async throws -> ProcessOutput {
        if executable == "/usr/sbin/pkgutil" { return ProcessOutput(code: 1, stdout: Data(), stderr: "Injected pkgutil failure") }
        return try await ProcessRunner().run(executable, arguments)
    }
}
private actor MockMountRunner: ProcessRunning {
    let fixtures: URL?
    init(fixtures: URL? = nil) { self.fixtures = fixtures }
    var active: URL?
    var detached = false
    func run(_ executable: String, _ arguments: [String]) async throws -> ProcessOutput {
        if executable != "/usr/bin/hdiutil" { return try await ProcessRunner().run(executable, arguments) }
        if arguments.first == "attach" {
            guard let index = arguments.firstIndex(of: "-mountroot") else { throw MachineError.invalid("Missing private mountroot") }
            let mount = URL(fileURLWithPath: arguments[index + 1]).appendingPathComponent("SyntheticVolume")
            try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: false)
            if let fixtures { for child in try SafeTree.children(fixtures) { try FileManager.default.copyItem(at: child, to: mount.appendingPathComponent(child.lastPathComponent)) } }
            active = mount
            try await Task.sleep(for: .milliseconds(120))
            return ProcessOutput(code: 0, stdout: try PropertyListSerialization.data(fromPropertyList: ["system-entities": [["mount-point": mount.path]]], format: .xml, options: 0), stderr: "")
        }
        if arguments.first == "detach" { active = nil; detached = true; return ProcessOutput(code: 0, stdout: Data(), stderr: "") }
        let images: [[String: Any]] = active.map { [["system-entities": [["mount-point": $0.path]]]] } ?? []
        return ProcessOutput(code: 0, stdout: try PropertyListSerialization.data(fromPropertyList: ["images": images], format: .xml, options: 0), stderr: "")
    }
}
