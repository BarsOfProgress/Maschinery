import XCTest
import Foundation
import Security
import Darwin
@testable import MaschineryCore

final class InstalledHelperTests: XCTestCase {
    private let fixtureHash = String(repeating: "a", count: 40)
    private func trust(app: [String]? = nil, helper: [String]? = nil, version: Int = 1) -> InstalledHelperTrust {
        InstalledHelperTrust(version: version, appHashes: app ?? [fixtureHash], helperHashes: helper ?? [String(repeating: "b", count: 40)], setupHashes: [String(repeating: "d", count: 40)])
    }
    private func fixture(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".maschinery-trust-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("trust.json")
        try JSONEncoder().encode(trust()).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        try body(file)
    }
    func testRequirementsCompileForBothArchitecturesAndAreRoleSpecific() throws {
        let value = trust(app: [fixtureHash, String(repeating: "c", count: 40)])
        let app = try value.requirement(identifier: HelperIdentity.app)
        let helper = try value.requirement(identifier: HelperIdentity.service)
        XCTAssertTrue(app.contains(" or "))
        XCTAssertFalse(helper.contains(fixtureHash))
        for text in [app, helper] {
            var requirement: SecRequirement?
            XCTAssertEqual(SecRequirementCreateWithString(text as CFString, [], &requirement), errSecSuccess)
        }
        XCTAssertThrowsError(try value.requirement(identifier: "untrusted.identifier"))
    }
    func testRejectsMalformedAndUnboundedIdentities() throws {
        for hashes in [[], [""], [String(repeating: "a", count: 39)], [String(repeating: "g", count: 40)], ["\" or true"], Array(repeating: fixtureHash, count: 9)] {
            XCTAssertThrowsError(try trust(app: hashes).requirement(identifier: HelperIdentity.app))
        }
        XCTAssertThrowsError(try trust(version: 2).requirement(identifier: HelperIdentity.app))
    }
    func testProtectedConfigurationAndRootOwnerEnforcement() throws {
        try fixture { url in
            let loaded = try InstalledHelperTrust.load(from: url, owner: getuid())
            XCTAssertEqual(loaded.appHashes, [fixtureHash])
            if getuid() != 0 { XCTAssertThrowsError(try InstalledHelperTrust.load(from: url, owner: 0)) }
        }
    }
    func testRejectsWritableFileAndParent() throws {
        try fixture { url in
            try FileManager.default.setAttributes([.posixPermissions: 0o622], ofItemAtPath: url.path)
            XCTAssertThrowsError(try InstalledHelperTrust.load(from: url, owner: getuid()))
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            try FileManager.default.setAttributes([.posixPermissions: 0o722], ofItemAtPath: url.deletingLastPathComponent().path)
            XCTAssertThrowsError(try InstalledHelperTrust.load(from: url, owner: getuid()))
        }
    }
    func testRejectsSymlinkAndHardlink() throws {
        try fixture { url in
            let alias = url.deletingLastPathComponent().appendingPathComponent("alias.json")
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: url)
            XCTAssertThrowsError(try InstalledHelperTrust.load(from: alias, owner: getuid()))
            try FileManager.default.removeItem(at: alias)
            try FileManager.default.linkItem(at: url, to: alias)
            XCTAssertThrowsError(try InstalledHelperTrust.load(from: url, owner: getuid()))
        }
    }
    func testRejectsDirectorySymlinkAndNonRegularConfiguration() throws {
        try fixture { url in
            let parent = url.deletingLastPathComponent()
            let alias = parent.appendingPathComponent("linked-directory")
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: parent)
            XCTAssertThrowsError(try InstalledHelperTrust.load(from: alias.appendingPathComponent("trust.json"), owner: getuid()))
            let fifo = parent.appendingPathComponent("fifo")
            XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
            XCTAssertThrowsError(try InstalledHelperTrust.load(from: fifo, owner: getuid()))
        }
    }
    func testRejectsOversizedMalformedAndInvalidOtherPeer() throws {
        try fixture { url in
            for data in [Data(repeating: 32, count: 8193), Data("{}".utf8), try JSONEncoder().encode(trust(helper: []))] {
                try data.write(to: url)
                XCTAssertThrowsError(try InstalledHelperTrust.load(from: url, owner: getuid()))
            }
        }
    }
    func testRejectsACLWriteGrant() throws {
        try fixture { url in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/chmod")
            process.arguments = ["+a", "user:\(NSUserName()) allow write", url.path]
            try process.run(); process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0)
            XCTAssertThrowsError(try InstalledHelperTrust.load(from: url, owner: getuid()))
        }
    }
    func testCurrentProcessCannotImpersonateApprovedApp() throws {
        XCTAssertThrowsError(try trust().validateCurrentApp())
    }
}
