import XCTest
@testable import MaschineryCore

final class IntegrationTests: XCTestCase {
    func testGeneratedPackageWithSeparateMetadataComponent() async throws {
        let fm = FileManager.default
        let workspace = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: workspace, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: workspace) }
        let payload = workspace.appendingPathComponent("payload"), metadata = workspace.appendingPathComponent("metadata")
        let samples = payload.appendingPathComponent("Test Library Part 1/Samples")
        let sc = metadata.appendingPathComponent("Library/Application Support/Native Instruments/Service Centre")
        try fm.createDirectory(at: samples, withIntermediateDirectories: true)
        try fm.createDirectory(at: sc, withIntermediateDirectories: true)
        try Data("dummy sample".utf8).write(to: samples.appendingPathComponent("sample.wav"))
        try Data("<ProductHints><Product><Name>Test</Name><ContentVersion>3.1</ContentVersion></Product></ProductHints>".utf8).write(to: sc.appendingPathComponent("Test.xml"))
        let runner = ProcessRunner()
        let contentPackage = workspace.appendingPathComponent("Test Library Part 1.pkg")
        let metadataPackage = workspace.appendingPathComponent("Test Installer.pkg")
        for (root, output, identifier) in [(payload, contentPackage, "test.content"), (metadata, metadataPackage, "test.metadata")] {
            let result = try await runner.run("/usr/bin/pkgbuild", ["--root", root.path, "--identifier", identifier, "--version", "1.0", "--install-location", "/", output.path])
            XCTAssertEqual(result.code, 0, result.stderr)
        }
        let result = try await ExpansionAnalyzer(log: LoggingService()).analyze([contentPackage, metadataPackage], destination: workspace.appendingPathComponent("destination"), offline: true)
        XCTAssertEqual(result.candidates.count, 1)
        XCTAssertEqual(result.candidates.first?.metadata?.name, "Test")
        XCTAssertEqual(result.candidates.first?.metadata?.version, "3.1")
        XCTAssertEqual(result.candidates.first?.payloads.count, 1)
        XCTAssertTrue(fm.fileExists(atPath: contentPackage.path))
    }
    func testProcessCaptureAndFailure() async throws {
        let result = try await ProcessRunner().run("/usr/bin/false", [])
        XCTAssertNotEqual(result.code, 0)
        let output = try await ProcessRunner().run("/usr/bin/printf", ["%s", "literal $(not-a-shell) ; &"])
        XCTAssertEqual(String(decoding: output.stdout, as: UTF8.self), "literal $(not-a-shell) ; &")
    }
    func testCancellationPreservesExistingContent() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: root) }
        let source = root.appendingPathComponent("source"), dest = root.appendingPathComponent("destination")
        try fm.createDirectory(at: source, withIntermediateDirectories: false)
        try fm.createDirectory(at: dest, withIntermediateDirectories: false)
        try Data(repeating: 1, count: 8 * 1024 * 1024).write(to: source.appendingPathComponent("large"))
        try Data("original".utf8).write(to: dest.appendingPathComponent("keep"))
        var candidate = ExpansionCandidate(name: "Test", sources: [], payloads: [source], destination: dest, size: 8 * 1024 * 1024)
        candidate.policy = .replace
        let plan = try InstallationPlanner.plan(candidate, mode: .extract)
        let task = Task {
            try await InstallationService(log: LoggingService()).execute(plan) { _ in
                // Cancellation at the next chunk boundary must discard staging, not the old library.
                withUnsafeCurrentTask { $0?.cancel() }
            }
        }
        do { try await task.value; XCTFail("Expected cancellation") } catch is CancellationError {} catch { XCTFail(error.localizedDescription) }
        XCTAssertEqual(try String(contentsOf: dest.appendingPathComponent("keep"), encoding: .utf8), "original")
        XCTAssertFalse(fm.fileExists(atPath: dest.appendingPathComponent("large").path))
    }
}
