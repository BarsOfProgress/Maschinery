import Foundation
import Darwin

public struct ProcessOutput: Sendable { public let code: Int32; public let stdout: Data; public let stderr: String }
public protocol ProcessRunning: Sendable { func run(_ executable: String, _ arguments: [String]) async throws -> ProcessOutput }
public struct ProcessRunner: ProcessRunning {
    public init() {}
    public func run(_ executable: String, _ arguments: [String]) async throws -> ProcessOutput {
        // File-backed capture avoids deadlocking on full stdout/stderr pipes.
        let directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let out = directory.appendingPathComponent("stdout"), err = directory.appendingPathComponent("stderr")
        FileManager.default.createFile(atPath: out.path, contents: nil); FileManager.default.createFile(atPath: err.path, contents: nil)
        let stdout = try FileHandle(forWritingTo: out), stderr = try FileHandle(forWritingTo: err)
        defer { try? stdout.close(); try? stderr.close() }
        let process = Process(); process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments; process.standardOutput = stdout; process.standardError = stderr
        try Task.checkCancellation(); try process.run()
        do {
            let started = Date()
            while process.isRunning {
                if Date().timeIntervalSince(started) > 1800 { throw MachineError.unavailable("Process timed out: " + URL(fileURLWithPath: executable).lastPathComponent) }
                try await Task.sleep(for: .milliseconds(100))
            }
            try Task.checkCancellation()
        } catch {
            if process.isRunning { process.terminate() }
            await Task.detached {
                for _ in 0..<40 { if !process.isRunning { return }; try? await Task.sleep(for: .milliseconds(50)) }
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }.value
            throw error
        }
        return ProcessOutput(code: process.terminationStatus, stdout: try Data(contentsOf: out), stderr: String(decoding: try Data(contentsOf: err), as: UTF8.self))
    }
}
public struct PackageExtractionService: Sendable {
    let runner: any ProcessRunning; let log: LoggingService
    public init(runner: any ProcessRunning = ProcessRunner(), log: LoggingService) { self.runner = runner; self.log = log }
    public func expand(_ pkg: URL, workspace: URL) async throws -> URL {
        let output = workspace.appendingPathComponent(UUID().uuidString)
        let result = try await runner.run("/usr/sbin/pkgutil", ["--expand-full", pkg.path, output.path])
        if result.code != 0 {
            await log.log(.warning, "pkgutil failed for \(pkg.lastPathComponent): \(result.stderr). Trying fallback.")
            if FileManager.default.fileExists(atPath: output.path) { try FileManager.default.removeItem(at: output) }
            if SafeTree.isDirectory(pkg) { try SafeTree.validate(pkg); try FileManager.default.copyItem(at: pkg, to: output) }
            else {
                guard FileManager.default.isExecutableFile(atPath: "/usr/bin/xar") else { throw MachineError.process("pkgutil (xar unavailable)", result.code, result.stderr) }
                try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
                // xar diagnostics are retained, but filesystem extraction is descriptor-confined libarchive.
                let listing = try await runner.run("/usr/bin/xar", ["-tf", pkg.path])
                await log.log(.warning, "xar inventory exit \(listing.code): \(listing.stderr)")
                try ArchiveExtraction.extract(pkg, into: output)

            }
        }
        try SafeTree.walk(output) { _ in true }
        var archives: [URL] = []
        try SafeTree.walk(output) { url in
            if !SafeTree.isDirectory(url), ["payload", "archive.pax.gz", "archive.pax"].contains(url.lastPathComponent.lowercased()) { archives.append(url) }
            return !LibraryRootDetector.isRoot(url)
        }
        for archive in archives {
            let target: URL
            if archive.lastPathComponent.lowercased() == "payload" {
                let saved = archive.appendingPathExtension("archive")
                try FileManager.default.moveItem(at: archive, to: saved)
                try ArchiveExtraction.extract(saved, into: archive)
            } else {
                target = output.appendingPathComponent("BundlePayload-" + UUID().uuidString)
                try ArchiveExtraction.extract(archive, into: target)
            }
        }
        return output
    }
}
public struct ISOService: Sendable {
    let runner: any ProcessRunning
    public init(runner: any ProcessRunning = ProcessRunner()) { self.runner = runner }
    public func attach(_ url: URL) async throws -> [URL] {
        let recovery = MountRecovery(log: LoggingService(), runner: runner)
        let root = try recovery.prepare(url)
        do {
            // Attach is a short non-cancellable system operation. Always collect its mount receipt, then honor cancellation.
            let runner = runner
            let result = try await Task.detached { try await runner.run("/usr/bin/hdiutil", ["attach", "-plist", "-readonly", "-nobrowse", "-noautoopen", "-mountroot", root.path, url.path]) }.value
            guard result.code == 0 else { throw MachineError.process("hdiutil attach", result.code, result.stderr) }
            guard let plist = try PropertyListSerialization.propertyList(from: result.stdout, format: nil) as? [String: Any], let entities = plist["system-entities"] as? [[String: Any]] else { throw MachineError.invalid("Image has no structured mount information") }
            let mounts = entities.compactMap { ($0["mount-point"] as? String).map { URL(fileURLWithPath: $0) } }
            guard !mounts.isEmpty, mounts.allSatisfy({ $0.path.hasPrefix(root.path + "/") }) else { throw MachineError.invalid("Image did not mount inside its private workspace") }
            try Task.checkCancellation(); return mounts
        } catch {
            do { try await Task.detached { try await recovery.cleanup(root) }.value }
            catch { throw MachineError.invalid("Image cleanup needs recovery: \(root.path): \(error.localizedDescription)") }
            throw error
        }
    }
    public func detach(_ mount: URL) async throws {
        try await MountRecovery(log: LoggingService(), runner: runner).cleanupAfterDetach(mount)
    }
}
