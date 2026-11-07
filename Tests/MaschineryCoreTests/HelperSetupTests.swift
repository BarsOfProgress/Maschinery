import XCTest
import Foundation
import Darwin
@testable import MaschineryCore

final class HelperSetupTests: XCTestCase {
    private func fixture(_ body: (HelperSetupInstaller) throws -> Void) throws {
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".maschinery-setup-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        for path in ["Library/Application Support/Maschinery", "Library/LaunchDaemons", "Applications"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(path), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        }
        let setup = HelperSetupInstaller(testRoot: root, owner: getuid())
        setup.serviceOperation = { _ in }
        setup.verifyCode = { _, _ in }
        setup.runningApp = { false }
        try payload(setup, label: "first")
        try body(setup)
    }
    private func write(_ path: String, _ value: String) throws {
        try Data(value.utf8).write(to: URL(fileURLWithPath: path))
        XCTAssertEqual(chmod(path, 0o600), 0)
    }
    private func payload(_ setup: HelperSetupInstaller, label: String) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: setup.payload) { try fm.removeItem(atPath: setup.payload) }
        for path in [setup.payload + "/Maschinery.app", setup.payload + "/InstalledHelper"] {
            try fm.createDirectory(atPath: path, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        }
        try write(setup.payload + "/Maschinery.app/version", label)
        try write(setup.payload + "/InstalledHelper/MaschineryHelper", label)
        try write(setup.payload + "/InstalledHelper/MaschinerySetup", label)
        try write(setup.payload + "/local.maschinery.helper.plist", label)
        let trust = InstalledHelperTrust(version: 1, appHashes: [String(repeating: "a", count: 40)], helperHashes: [String(repeating: "b", count: 40)], setupHashes: [String(repeating: "d", count: 40)])
        try JSONEncoder().encode(trust).write(to: URL(fileURLWithPath: setup.payload + "/InstalledHelper/trust.json"))
    }
    private func version(_ setup: HelperSetupInstaller) throws -> String { try String(contentsOfFile: setup.app + "/version", encoding: .utf8) }
    func testInstallUpdateAndUninstallPreserveAppAndLibraryData() throws {
        try fixture { setup in
            var operations: [String] = []
            setup.serviceOperation = { operations.append($0) }
            try setup.execute("install")
            XCTAssertEqual(try version(setup), "first")
            XCTAssertTrue(FileManager.default.fileExists(atPath: setup.installed + "/trust.json"))
            try payload(setup, label: "second")
            try setup.execute("install")
            XCTAssertEqual(try version(setup), "second")
            let journals = setup.base + "/Transactions"
            try FileManager.default.createDirectory(atPath: journals, withIntermediateDirectories: true)
            try write(journals + "/receipt.json", "{\"phase\":\"committed\"}")
            try setup.execute("uninstall")
            XCTAssertEqual(try version(setup), "second")
            XCTAssertTrue(FileManager.default.fileExists(atPath: journals + "/receipt.json"))
            XCTAssertFalse(FileManager.default.fileExists(atPath: setup.installed))
            XCTAssertFalse(FileManager.default.fileExists(atPath: setup.daemon))
            XCTAssertEqual(operations, ["stop", "start", "stop", "start", "stop"])
        }
    }
    func testFailedNewHelperStartupRestoresPreviousBuild() throws {
        try fixture { setup in
            try setup.execute("install")
            try payload(setup, label: "second")
            var failed = false
            setup.serviceOperation = { action in
                if action == "start" && !failed { failed = true; throw CocoaError(.fileWriteUnknown) }
            }
            XCTAssertThrowsError(try setup.execute("install"))
            XCTAssertEqual(try version(setup), "first")
            XCTAssertEqual(try String(contentsOfFile: setup.daemon, encoding: .utf8), "first")
            XCTAssertFalse(FileManager.default.fileExists(atPath: setup.state))
        }
    }
    func testFailureAtEachReplacementRollsBackAllComponents() throws {
        for component in ["app", "helper", "daemon"] {
            try fixture { setup in
                try setup.execute("install")
                try payload(setup, label: "second")
                var failed = false
                setup.afterMove = { source, _ in
                    if source == setup.state + "/new-" + component && !failed { failed = true; throw CocoaError(.fileWriteUnknown) }
                }
                XCTAssertThrowsError(try setup.execute("install"))
                XCTAssertTrue(failed)
                XCTAssertEqual(try version(setup), "first")
                XCTAssertEqual(try String(contentsOfFile: setup.installed + "/MaschineryHelper", encoding: .utf8), "first")
                XCTAssertEqual(try String(contentsOfFile: setup.daemon, encoding: .utf8), "first")
            }
        }
    }
    func testFirstInstallFailureRemovesPartialInstallation() throws {
        try fixture { setup in
            setup.serviceOperation = { action in if action == "start" { throw CocoaError(.fileWriteUnknown) } }
            XCTAssertThrowsError(try setup.execute("install"))
            for path in [setup.app, setup.installed, setup.daemon, setup.state] { XCTAssertFalse(FileManager.default.fileExists(atPath: path)) }
        }
    }
    func testRecoveryAfterInterruptedReplacementIsRepeatable() throws {
        try fixture { setup in
            try setup.execute("install")
            try FileManager.default.createDirectory(atPath: setup.state, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            try setup.marker("ready"); try setup.marker("app.changed")
            try setup.move(setup.app, setup.state + "/app")
            try FileManager.default.createDirectory(atPath: setup.app, withIntermediateDirectories: false)
            try write(setup.app + "/version", "incomplete")
            try setup.execute("recover")
            XCTAssertEqual(try version(setup), "first")
            try setup.execute("recover")
            XCTAssertEqual(try version(setup), "first")
        }
    }
    func testCommittedUpdateCleanupDoesNotRevert() throws {
        try fixture { setup in
            try setup.execute("install")
            try FileManager.default.createDirectory(atPath: setup.state, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            try setup.marker("ready"); try setup.marker("committed")
            try setup.execute("recover")
            XCTAssertEqual(try version(setup), "first")
            XCTAssertFalse(FileManager.default.fileExists(atPath: setup.state))
        }
    }
    func testRunningAppAndUnfinishedTransactionsBlockChanges() throws {
        try fixture { setup in
            setup.runningApp = { true }
            XCTAssertThrowsError(try setup.execute("install"))
            setup.runningApp = { false }
            let journals = setup.base + "/Transactions"
            try FileManager.default.createDirectory(atPath: journals, withIntermediateDirectories: true)
            try write(journals + "/pending.json", "{\"phase\":\"applied\"}")
            XCTAssertThrowsError(try setup.execute("install"))
            XCTAssertThrowsError(try setup.execute("uninstall"))
            XCTAssertFalse(FileManager.default.fileExists(atPath: setup.app))
        }
    }
    func testRejectsPayloadLinksAndFailedSignatureBeforeServiceChanges() throws {
        try fixture { setup in
            var serviceChanged = false
            setup.serviceOperation = { _ in serviceChanged = true }
            let link = setup.payload + "/link"
            try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: "/etc/passwd")
            XCTAssertThrowsError(try setup.execute("install"))
            try FileManager.default.removeItem(atPath: link)
            setup.verifyCode = { _, _ in throw CocoaError(.fileReadCorruptFile) }
            XCTAssertThrowsError(try setup.execute("install"))
            XCTAssertFalse(serviceChanged)
        }
    }
    func testProductionSignatureCheckAcceptsExpressionAndRejectsWrongPeer() throws {
        try fixture { setup in
            setup.verifyCode = nil
            try setup.checkCode("/usr/bin/true", requirement: "anchor apple")
            XCTAssertThrowsError(try setup.checkCode("/usr/bin/true", requirement: "identifier \"local.maschinery.app\""))
        }
    }

    func testInterruptedCommittedCleanupNeverRollsBack() throws {
        try fixture { setup in
            try setup.execute("install")
            try FileManager.default.createDirectory(atPath: setup.state, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            try setup.marker("ready"); try setup.marker("committed")
            setup.afterMove = { source, _ in
                if source == setup.state { throw CocoaError(.fileWriteUnknown) }
            }
            XCTAssertThrowsError(try setup.execute("recover"))
            XCTAssertFalse(FileManager.default.fileExists(atPath: setup.state))
            setup.afterMove = nil
            try setup.execute("recover")
            XCTAssertEqual(try version(setup), "first")
            XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: setup.base).contains { $0.hasPrefix("HelperSetupGarbage-") })
        }
    }

}
