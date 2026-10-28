import Foundation
import Darwin

public struct SharedContentRequest: Codable, Sendable {
    public let transaction: UUID, product: String, destination: String
    public init(transaction: UUID, product: String, destination: String) { self.transaction = transaction; self.product = product; self.destination = destination }
}
/// The ONLY privileged payload capability: rename a direct, product-named /Users/Shared library.
/// Arbitrary user destinations never pass this boundary.
public enum SharedContentOperations {
    private static func directories(_ request: SharedContentRequest, user: uid_t) throws -> (SecureDirectory, SecureDirectory, String) {
        try RegistrationValidation.product(request.product)
        let destination = URL(fileURLWithPath: request.destination)
        guard destination.deletingLastPathComponent().path == "/Users/Shared", ProductName.key(destination.lastPathComponent) == ProductName.key(request.product), !["niresources", "maschinemachine"].contains(ProductName.key(request.product)), !destination.lastPathComponent.hasPrefix(".") else { throw MachineError.invalid("Privileged payload operations are restricted to a direct product-named library in /Users/Shared") }
        let shared = try SecureDirectory(root: URL(fileURLWithPath: "/Users/Shared"), create: false)
        let name = ".maschine-" + request.transaction.uuidString
        let fd = openat(shared.fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw SecureDirectory.failure("open shared staging") }; defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == user, info.st_mode & 0o077 == 0 else { throw MachineError.invalid("Shared staging must be private and owned by the requesting user") }
        return (shared, SecureDirectory(fd: dup(fd)), destination.lastPathComponent)
    }
    static func validateExisting(_ directory: SecureDirectory, product: String, destination: String, preferences: SecureDirectory) throws {
        let marker = openat(directory.fd, "PAResources", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if marker >= 0 { close(marker); return }
        if let (data, _) = try preferences.read("com.native-instruments.\(product).plist", createParents: false),
           let values = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any], values["ContentDir"] as? String == destination { return }
        throw MachineError.invalid("The existing shared directory has neither PAResources nor a matching NI registration; privileged replacement is refused")
    }
    public static func swap(_ request: SharedContentRequest, user: uid_t) throws {
        let (shared, staging, name) = try directories(request, user: user)
        let content = openat(staging.fd, "content", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard content >= 0 else { throw SecureDirectory.failure("open staged library") }; defer { close(content) }
        var info = stat()
        guard fstat(content, &info) == 0, info.st_uid == user else { throw MachineError.invalid("Staged library ownership changed") }
        if fstatat(staging.fd, "previous", &info, AT_SYMLINK_NOFOLLOW) == 0 { throw MachineError.invalid("Shared backup already exists; recover the transaction") }
        var hadOld = false
        if fstatat(shared.fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0 {
            guard info.st_mode & S_IFMT == S_IFDIR else { throw MachineError.invalid("Shared destination is not a directory") }
            let existingFD = openat(shared.fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard existingFD >= 0 else { throw SecureDirectory.failure("inspect existing shared library") }
            let existing = SecureDirectory(fd: existingFD)
            try validateExisting(existing, product: request.product, destination: request.destination, preferences: SecureDirectory(root: URL(fileURLWithPath: "/Library/Preferences"), create: false))
            guard renameat(shared.fd, name, staging.fd, "previous") == 0 else { throw SecureDirectory.failure("back up shared library") }; hadOld = true
        } else if errno != ENOENT { throw SecureDirectory.failure("inspect shared destination") }
        if renameat(staging.fd, "content", shared.fd, name) != 0 {
            let reason = SecureDirectory.failure("commit shared library")
            if hadOld && renameat(staging.fd, "previous", shared.fd, name) != 0 { throw MachineError.invalid("Shared library recovery required: \(request.transaction)") }
            throw reason
        }
        _ = fsync(shared.fd); _ = fsync(staging.fd)
    }
    public static func restore(_ request: SharedContentRequest, user: uid_t) throws {
        let (shared, staging, name) = try directories(request, user: user)
        var info = stat()
        guard fstatat(staging.fd, "previous", &info, AT_SYMLINK_NOFOLLOW) == 0 else { return }
        guard info.st_mode & S_IFMT == S_IFDIR else { throw MachineError.invalid("Shared recovery backup changed") }
        if fstatat(shared.fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0 {
            guard info.st_mode & S_IFMT == S_IFDIR else { throw MachineError.invalid("Shared destination changed during recovery") }
            guard renameat(shared.fd, name, staging.fd, "discarded") == 0 else { throw SecureDirectory.failure("stage failed shared content") }
        }
        guard renameat(staging.fd, "previous", shared.fd, name) == 0 else { throw SecureDirectory.failure("restore shared library") }
        try removeTree(staging.fd, "discarded")
    }
    public static func cleanup(_ request: SharedContentRequest, user: uid_t) throws {
        let (_, staging, _) = try directories(request, user: user)
        try removeTree(staging.fd, "previous")
    }
    private static func removeTree(_ parent: Int32, _ name: String) throws {
        var info = stat()
        if fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) != 0 { if errno == ENOENT { return }; throw SecureDirectory.failure("inspect old shared library") }
        if info.st_mode & S_IFMT == S_IFDIR {
            let fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw SecureDirectory.failure("open old shared library") }
            guard let directory = fdopendir(fd) else { close(fd); throw SecureDirectory.failure("enumerate old shared library") }
            defer { closedir(directory) }
            while let entry = readdir(directory) {
                let child = withUnsafePointer(to: &entry.pointee.d_name) { pointer in pointer.withMemoryRebound(to: CChar.self, capacity: 1024) { String(cString: $0) } }
                if child != "." && child != ".." { try removeTree(fd, child) }
            }
            guard unlinkat(parent, name, AT_REMOVEDIR) == 0 else { throw SecureDirectory.failure("remove old shared directory") }
        } else {
            // Unlink the directory entry itself. Never follow old installer symlinks.
            guard unlinkat(parent, name, 0) == 0 else { throw SecureDirectory.failure("remove old shared file") }
        }
    }
}
