import Foundation
import Darwin

/// All privileged IO is relative to pinned directory descriptors. No caller-supplied absolute write path.
final class SecureDirectory {
    let fd: Int32
    init(root: URL, create: Bool = true) throws {
        var current = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard current >= 0 else { throw Self.failure("open root") }
        do {
            let absolute = root.path.hasPrefix("/var/") || root.path.hasPrefix("/tmp/") ? "/private" + root.path : root.path
            for part in absolute.split(separator: "/").map(String.init) {
                guard part != "..", part != "." else { throw MaschineryError.invalid("Unsafe directory component") }
                if create && mkdirat(current, part, 0o755) != 0 && errno != EEXIST { throw Self.failure("create NI directory") }
                let next = openat(current, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard next >= 0 else { throw Self.failure("open NI directory without following links") }
                close(current); current = next
            }
            fd = current
        } catch { close(current); throw error }
    }
    init(fd: Int32) { self.fd = fd }
    deinit { close(fd) }
    static func failure(_ operation: String) -> MaschineryError { .invalid("\(operation): \(String(cString: strerror(errno)))") }
    func parent(_ path: String, create: Bool) throws -> (SecureDirectory, String) {
        try RegistrationValidation.relative(path)
        let components = path.split(separator: "/").map(String.init)
        var current = dup(fd)
        guard current >= 0 else { throw Self.failure("duplicate directory") }
        do {
            for part in components.dropLast() {
                if create && mkdirat(current, part, 0o755) != 0 && errno != EEXIST { throw Self.failure("create resource directory") }
                let next = openat(current, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard next >= 0 else { throw Self.failure("open resource directory") }; close(current); current = next
            }; return (SecureDirectory(fd: current), components.last!)
        } catch { close(current); throw error }
    }
    func read(_ path: String, maximum: Int64 = 64 * 1024 * 1024, createParents: Bool = true) throws -> (Data, UInt16)? {
        let (directory, name) = try parent(path, create: createParents)
        let file = openat(directory.fd, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if file < 0 && errno == ENOENT { return nil }
        guard file >= 0 else { throw Self.failure("read NI file") }; defer { close(file) }
        var info = stat(); guard fstat(file, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1, info.st_size <= maximum else { throw MaschineryError.invalid("NI target is not a bounded regular file with one link") }
        var result = Data(); var buffer = [UInt8](repeating: 0, count: 65536)
        while true { let count = Darwin.read(file, &buffer, buffer.count); guard count >= 0 else { throw Self.failure("read registration") }; if count == 0 { break }; result.append(contentsOf: buffer.prefix(count)); guard result.count <= maximum else { throw MaschineryError.invalid("NI file exceeds limit") } }
        return (result, UInt16(info.st_mode & 0o777))
    }
    func write(_ path: String, data: Data, mode: UInt16 = 0o644, maximumExisting: Int64 = 64 * 1024 * 1024) throws {
        let (directory, name) = try parent(path, create: true)
        // Validate even when replacing: reject links, devices, and multiply-linked targets.
        _ = try read(path, maximum: maximumExisting)
        let temporary = ".maschinery-\(UUID().uuidString)"
        let file = openat(directory.fd, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard file >= 0 else { throw Self.failure("stage registration") }
        defer { close(file); unlinkat(directory.fd, temporary, 0) }
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count { let count = Darwin.write(file, raw.baseAddress!.advanced(by: offset), raw.count - offset); guard count > 0 else { throw Self.failure("write registration") }; offset += count }
        }
        guard fchmod(file, mode_t(mode)) == 0, fsync(file) == 0 else { throw Self.failure("sync registration") }
        guard renameat(directory.fd, temporary, directory.fd, name) == 0 else { throw Self.failure("commit registration") }
        guard fsync(directory.fd) == 0 else { throw Self.failure("sync registration directory") }
    }
    func remove(_ path: String) throws {
        let (directory, name) = try parent(path, create: false)
        _ = try read(path)
        guard unlinkat(directory.fd, name, 0) == 0 || errno == ENOENT else { throw Self.failure("remove transaction file") }
        guard fsync(directory.fd) == 0 else { throw Self.failure("sync removal") }
    }
}
