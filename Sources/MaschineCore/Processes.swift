import Foundation

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
            while process.isRunning { try await Task.sleep(for: .milliseconds(100)) }
            try Task.checkCancellation()
        } catch {
            if process.isRunning { process.terminate() }
            while process.isRunning { try? await Task.sleep(for: .milliseconds(50)) }
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
                // Inspect archive member names before extraction. No absolute or parent-relative members.
                let listing = try await runner.run("/usr/bin/xar", ["-tf", pkg.path])
                guard listing.code == 0 else { throw MachineError.process("xar list", listing.code, listing.stderr) }
                let paths = String(decoding: listing.stdout, as: UTF8.self).split(separator: "\n")
                guard paths.allSatisfy({ !$0.hasPrefix("/") && !$0.split(separator: "/").contains("..") }) else { throw MachineError.invalid("Unsafe package archive paths") }
                let fallback = try await runner.run("/usr/bin/xar", ["-xf", pkg.path, "-C", output.path])
                await log.log(.warning, "xar fallback exit \(fallback.code): \(fallback.stderr)")
                guard !(try SafeTree.children(output)).isEmpty else { throw MachineError.process("xar", fallback.code, fallback.stderr) }
            }
        }
        try SafeTree.walk(output) { _ in true }
        return output
    }
}
public struct ISOService: Sendable {
    let runner: any ProcessRunning
    public init(runner: any ProcessRunning = ProcessRunner()) { self.runner = runner }
    public func attach(_ url: URL) async throws -> [URL] {
        let result = try await runner.run("/usr/bin/hdiutil", ["attach", "-plist", "-readonly", "-nobrowse", url.path])
        guard result.code == 0 else { throw MachineError.process("hdiutil attach", result.code, result.stderr) }
        guard let plist = try PropertyListSerialization.propertyList(from: result.stdout, format: nil) as? [String: Any], let entities = plist["system-entities"] as? [[String: Any]] else { throw MachineError.invalid("hdiutil returned no structured mount information") }
        let mounts = entities.compactMap { ($0["mount-point"] as? String).map { URL(fileURLWithPath: $0) } }
        guard !mounts.isEmpty else { throw MachineError.invalid("Image contains no readable mounted volume") }; return mounts
    }
    public func detach(_ mount: URL) async throws {
        let result = try await runner.run("/usr/bin/hdiutil", ["detach", mount.path])
        guard result.code == 0 else { throw MachineError.process("hdiutil detach", result.code, result.stderr) }
    }
}
