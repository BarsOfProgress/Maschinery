import Foundation
import Security
import Darwin

/// Fixed-path package installation. The GUI and XPC helper never expose this API remotely.
public final class HelperSetupInstaller {
    let root: String
    let owner: uid_t
    var base: String { root + "/Library/Application Support/Maschinery" }
    var payload: String { base + "/InstallerPayload" }
    var installed: String { base + "/InstalledHelper" }
    var state: String { base + "/HelperSetupBackup" }
    var app: String { root + "/Applications/Maschinery.app" }
    var daemon: String { root + "/Library/LaunchDaemons/local.maschinery.helper.plist" }
    let service = "system/local.maschinery.helper"
    var serviceOperation: ((String) throws -> Void)?
    var verifyCode: ((String, String) throws -> Void)?
    var runningApp: (() throws -> Bool)?
    var afterMove: ((String, String) throws -> Void)?

    public init() { root = ""; owner = 0 }
    // Only unit tests can select isolated roots and replace OS service management.
    init(testRoot: URL, owner: uid_t) { root = testRoot.path; self.owner = owner }
    struct SetupError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
    func fail(_ message: String) throws -> Never { throw SetupError(message: message) }
    func exists(_ path: String) -> Bool { var s = stat(); return lstat(path, &s) == 0 }
    func protected(_ path: String, directory: Bool = true) throws {
        var current = ""
        for component in path.split(separator: "/") {
            current += "/" + component
            var info = stat()
            guard lstat(current, &info) == 0, (info.st_uid == owner || (current != path && info.st_uid == 0)), info.st_mode & 0o022 == 0,
                  info.st_mode & S_IFMT == (current == path && !directory ? S_IFREG : S_IFDIR) else {
                try fail("Unsafe installation path: \(current). It must be root-owned, without links or group/world write access.")
            }
            if let acl = acl_get_file(current, ACL_TYPE_EXTENDED) {
                defer { acl_free(UnsafeMutableRawPointer(acl)) }
                var entry: acl_entry_t?
                var result = acl_get_entry(acl, Int32(ACL_FIRST_ENTRY.rawValue), &entry)
                while result == 0, let entryValue = entry {
                    var tag = ACL_UNDEFINED_TAG
                    guard acl_get_tag_type(entryValue, &tag) == 0, tag == ACL_EXTENDED_DENY else {
                        try fail("Unexpected ACL grant at \(current)")
                    }
                    result = acl_get_entry(acl, Int32(ACL_NEXT_ENTRY.rawValue), &entry)
                }
            } else if errno != ENOENT && errno != ENOTSUP { try fail("Cannot check ACL at \(current)") }
        }
    }
    func makeDirectory(_ path: String, mode: mode_t = 0o755) throws {
        try protected((path as NSString).deletingLastPathComponent)
        if !exists(path) {
            guard mkdir(path, mode) == 0 else { try fail("Cannot create \(path)") }
        }
        try protected(path)
    }
    func run(_ executable: String, _ arguments: [String], allowFailure: Bool = false) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": "/var/root"]
        try process.run(); process.waitUntilExit()
        if process.terminationStatus != 0 && !allowFailure { try fail("\((executable as NSString).lastPathComponent) failed (\(process.terminationStatus)).") }
    }
    func validateTree(_ path: String) throws {
        try protected(path)
        var enumerationError: Error?
        guard let enumerator = FileManager.default.enumerator(at: URL(fileURLWithPath: path), includingPropertiesForKeys: nil, errorHandler: { _, error in
            enumerationError = error; return false
        }) else { try fail("Cannot enumerate payload") }
        while let child = enumerator.nextObject() as? URL {
            var info = stat()
            guard lstat(child.path, &info) == 0,
                  [S_IFDIR, S_IFREG].contains(info.st_mode & S_IFMT),
                  info.st_uid == owner, info.st_mode & 0o022 == 0,
                  info.st_mode & S_IFMT != S_IFREG || info.st_nlink == 1 else { try fail("Unsafe payload: \(child.path)") }
            try protected(child.path, directory: info.st_mode & S_IFMT == S_IFDIR)
        }
        if let enumerationError { throw enumerationError }
    }
    func synchronizeStaging() throws {
        guard let enumerator = FileManager.default.enumerator(atPath: state) else { try fail("Cannot enumerate installer staging") }
        var paths = [state]
        while let name = enumerator.nextObject() as? String { paths.append(state + "/" + name) }
        for path in paths.reversed() {
            let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { try fail("Cannot synchronize staged installation") }
            let result = fsync(fd); close(fd)
            guard result == 0 else { try fail("Cannot persist staged installation") }
        }
    }
    func checkCode(_ path: String, requirement: String) throws {
        if let verifyCode { try verifyCode(path, requirement); return }
        try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", "--all-architectures", "-R", "=" + requirement, path])
    }
    func move(_ source: String, _ destination: String) throws {
        // Atomic rename never follows an existing destination symlink. Refuse cross-volume copies.
        guard rename(source, destination) == 0 else { try fail("Cannot atomically move \(source) to \(destination): \(String(cString: strerror(errno)))") }
        for parent in Set([(source as NSString).deletingLastPathComponent, (destination as NSString).deletingLastPathComponent]) {
            let fd = open(parent, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            guard fd >= 0 else { try fail("Cannot open installation directory for synchronization") }
            let result = fsync(fd); close(fd)
            guard result == 0 else { try fail("Cannot persist installation rename") }
        }
        try afterMove?(source, destination)
    }
    func appIsRunning() throws -> Bool {
        if let runningApp { return try runningApp() }
        // Check all users. Do not update underneath an operation started by a different login session.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-x", "Maschinery"]
        process.standardOutput = FileHandle.nullDevice
        try process.run(); process.waitUntilExit()
        guard process.terminationStatus == 0 || process.terminationStatus == 1 else { try fail("Cannot check running app processes") }
        return process.terminationStatus == 0
    }
    func unload() throws {
        if let serviceOperation { try serviceOperation("stop"); return }
        try run("/bin/launchctl", ["bootout", service], allowFailure: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["print", service]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit()
        guard process.terminationStatus != 0 else { try fail("The old helper is still loaded. No installation files were replaced.") }
    }
    func load() throws {
        if let serviceOperation { try serviceOperation("start"); return }
        // Validate a restored installation too, before executing any saved setup tool.
        try validateTree(installed)
        try protected(daemon, directory: false)
        let trust = try InstalledHelperTrust.load()
        try checkCode(installed + "/MaschineryHelper", requirement: trust.requirement(identifier: HelperIdentity.service))
        try checkCode(installed + "/MaschinerySetup", requirement: trust.requirement(identifier: HelperIdentity.setup))
        try run("/bin/launchctl", ["enable", service])
        try run("/bin/launchctl", ["bootstrap", "system", daemon])
        try run(installed + "/MaschinerySetup", ["check"])
    }
    func restore() throws {
        guard exists(state + "/ready") else {
            // No mutation was allowed before this marker. A partial snapshot can be discarded.
            if exists(state) { try protected(state); try FileManager.default.removeItem(atPath: state) }
            return
        }
        try protected(state)
        try unload()
        for (live, name) in [(app, "app"), (installed, "helper"), (daemon, "daemon")] {
            let backup = state + "/" + name
            // A per-component marker is durable before the original is moved. If it has not
            // moved yet, leave the original in place; otherwise restore the saved object.
            if exists(state + "/" + name + ".changed") {
                if exists(backup) {
                    if exists(live) {
                        let discarded = state + "/discard-" + name
                        if exists(discarded) { try FileManager.default.removeItem(atPath: discarded) }
                        try move(live, discarded)
                    }
                    try move(backup, live)
                } else if exists(state + "/" + name + ".absent"), exists(live) {
                    let discarded = state + "/discard-" + name
                    if exists(discarded) { try FileManager.default.removeItem(atPath: discarded) }
                    try move(live, discarded)
                }
            }
        }
        if exists(daemon) { try load() }
        try FileManager.default.removeItem(atPath: state)
    }
    func marker(_ name: String) throws {
        let fd = open(state + "/" + name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { try fail("Cannot write installer recovery marker") }
        guard fsync(fd) == 0 else { close(fd); try fail("Cannot persist installer recovery marker") }
        close(fd)
        let directory = open(state, O_RDONLY | O_DIRECTORY)
        guard directory >= 0 else { try fail("Cannot open installer recovery directory") }
        defer { close(directory) }
        guard fsync(directory) == 0 else { try fail("Cannot persist installer recovery directory") }
    }
    func install() throws {
        try validateTree(payload)
        try requireCompletedTransactions()
        let data = try Data(contentsOf: URL(fileURLWithPath: payload + "/InstalledHelper/trust.json"))
        let trust = try JSONDecoder().decode(InstalledHelperTrust.self, from: data)
        try checkCode(payload + "/Maschinery.app", requirement: trust.requirement(identifier: HelperIdentity.app))
        try checkCode(payload + "/InstalledHelper/MaschineryHelper", requirement: trust.requirement(identifier: HelperIdentity.service))
        try checkCode(payload + "/InstalledHelper/MaschinerySetup", requirement: trust.requirement(identifier: HelperIdentity.setup))
        if exists(state) { try restore() }
        // Require the legacy SMAppService installation to be removed first. Its owner
        // must unregister it; otherwise macOS can reactivate the obsolete job.
        if serviceOperation == nil, !exists(installed), exists(app + "/Contents/Library/LaunchDaemons/local.maschinery.helper.plist") {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            process.arguments = ["print", service]
            process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            try process.run(); process.waitUntilExit()
            if process.terminationStatus == 0 { try fail("Disable and unregister the old signed helper in Maschinery before installing this package.") }
        }
        try makeDirectory(state, mode: 0o700)
        // Everything is staged in a protected directory, never a user-writable /tmp directory.
        try FileManager.default.copyItem(atPath: payload + "/Maschinery.app", toPath: state + "/new-app")
        try FileManager.default.copyItem(atPath: payload + "/InstalledHelper", toPath: state + "/new-helper")
        try FileManager.default.copyItem(atPath: payload + "/local.maschinery.helper.plist", toPath: state + "/new-daemon")
        for (live, name) in [(app, "app"), (installed, "helper"), (daemon, "daemon")] {
            if !exists(live) { try marker(name + ".absent") }
        }
        try synchronizeStaging()
        try marker("ready")
        do {
            try unload()
            try requireCompletedTransactions()
            guard !(try appIsRunning()) else { try fail("Maschinery was reopened during setup. Quit it and retry.") }
            for (live, name) in [(app, "app"), (installed, "helper"), (daemon, "daemon")] {
                try marker(name + ".changed")
                if exists(live) { try move(live, state + "/" + name) }
                try move(state + "/new-" + name, live)
            }
            _ = try InstalledHelperTrust.load(from: URL(fileURLWithPath: installed + "/trust.json"), owner: owner)
            try load()
            // A completed marker makes a subsequent run finish cleanup instead of reverting.
            try marker("committed")
        } catch {
            do { try restore() } catch { fputs("Rollback incomplete: \(error.localizedDescription). Rerun the installer to recover.\n", stderr) }
            throw error
        }
        try retireCommittedState()
        if exists(payload) { try FileManager.default.removeItem(atPath: payload) }
        print("Maschinery and its helper are installed. Open Maschinery from Applications.")
    }
    func retireCommittedState() throws {
        // Remove the recovery name atomically before deleting backups. A crash during
        // recursive cleanup must never turn a committed update into a partial rollback.
        try protected(state)
        let retired = base + "/HelperSetupGarbage-" + UUID().uuidString
        try move(state, retired)
        do { try FileManager.default.removeItem(atPath: retired) }
        catch { fputs("Setup completed; old backup cleanup will be retried later.\n", stderr) }
    }
    func cleanRetiredStates() throws {
        for name in try FileManager.default.contentsOfDirectory(atPath: base) where name.hasPrefix("HelperSetupGarbage-") {
            let path = base + "/" + name
            try protected(path)
            try FileManager.default.removeItem(atPath: path)
        }
    }
    func requireCompletedTransactions() throws {
        let journals = base + "/Transactions"
        guard exists(journals) else { return }
        try protected(journals)
        guard let enumerator = FileManager.default.enumerator(atPath: journals) else { try fail("Cannot inspect recovery journals") }
        while let name = enumerator.nextObject() as? String {
            let path = journals + "/" + name
            var info = stat()
            guard lstat(path, &info) == 0, [S_IFREG, S_IFDIR].contains(info.st_mode & S_IFMT) else { try fail("Unsafe recovery journal") }
            if name.hasSuffix(".json") {
                try protected(path, directory: false)
                let object = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path)))
                guard let phase = (object as? [String: Any])?["phase"] as? String,
                      ["committed", "rolledBack"].contains(phase) else {
                    try fail("Recover unfinished library operations in Maschinery before updating or removing its helper.")
                }
            }
        }
    }
    func uninstall() throws {
        try requireCompletedTransactions()
        if exists(state) { try restore() }
        guard exists(installed) else { return }
        _ = try InstalledHelperTrust.load(from: URL(fileURLWithPath: installed + "/trust.json"), owner: owner)
        try unload()
        do {
            try requireCompletedTransactions()
            guard !(try appIsRunning()) else { try fail("Maschinery was reopened during setup. Quit it and retry.") }
        } catch {
            if exists(daemon) { try load() }
            throw error
        }
        if exists(daemon) { try FileManager.default.removeItem(atPath: daemon) }
        try FileManager.default.removeItem(atPath: installed)
        if exists(payload) { try validateTree(payload); try FileManager.default.removeItem(atPath: payload) }
        print("Helper removed. Libraries, NI registrations, recovery journals and the app were retained.")
    }

    public func execute(_ operation: String) throws {
        guard geteuid() == owner else { try fail("Run this tool through the administrator-authorized Maschinery installer.") }
        guard ["prepare", "install", "recover", "uninstall"].contains(operation) else { try fail("Unknown setup operation") }
        guard !(try appIsRunning()) else { try fail("Quit Maschinery in every login session, then run the installer again.") }
        try protected(root + "/Library/Application Support")
        try makeDirectory(base)
        try protected(root + "/Library/LaunchDaemons")
        var applicationsInfo = stat()
        guard lstat(root + "/Applications", &applicationsInfo) == 0,
              applicationsInfo.st_uid == owner, applicationsInfo.st_mode & S_IFMT == S_IFDIR else { try fail("Invalid Applications directory") }
        if exists(state + "/committed") { try retireCommittedState() }
        try cleanRetiredStates()
        switch operation {
        case "prepare":
            try requireCompletedTransactions()
            if exists(payload) { try validateTree(payload); try FileManager.default.removeItem(atPath: payload) }
        case "install": try install()
        case "recover": try restore()
        case "uninstall": try uninstall()
        default: break
        }
    }
}
