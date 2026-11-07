import Foundation
import Darwin

struct PermissionBackup: Codable {
    let path: String, mode: UInt16, inode: UInt64, device: Int32
    var owner: UInt32? = nil
    var group: UInt32? = nil
}
enum SharedPermissions {
    static func scope(_ request: RegistrationRequest, preferences: SecureDirectory) throws -> SecureDirectory {
        let path = URL(fileURLWithPath: request.contentPath)
        guard path.deletingLastPathComponent().path == "/Users/Shared", ProductName.key(path.lastPathComponent) == ProductName.key(request.product), !["niresources", "maschinery"].contains(ProductName.key(request.product)), !path.lastPathComponent.hasPrefix(".") else { throw MaschineryError.invalid("Privileged permission repair is restricted to the product’s registered library directly in /Users/Shared") }
        guard let (data, _) = try preferences.read("com.native-instruments.\(request.product).plist"),
              let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any], (plist["ContentDir"] as? String).flatMap(ExistingLibraryService.contentURL)?.standardizedFileURL.path == request.contentPath else { throw MaschineryError.invalid("Legacy permission transaction has no matching resolved NI ContentDir; recover it using its original expansion path") }
        let root = try SecureDirectory(root: path, create: false)
        let marker = openat(root.fd, "PAResources", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard marker >= 0 else { throw MaschineryError.invalid("Permission repair requires a genuine PAResources library root") }; close(marker)
        return root
    }
    static func entries(_ fd: Int32) throws -> [String] {
        // dup shares a directory's seek offset. A fresh open description is
        // required so repeated proof/snapshot/verification walks see all entries.
        let copy = openat(fd, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard copy >= 0 else { throw SecureDirectory.failure("open scoped directory for enumeration") }
        guard let stream = fdopendir(copy) else {
            let error = errno; close(copy); errno = error
            throw SecureDirectory.failure("enumerate scoped library")
        }
        defer { closedir(stream) }
        var names: [String] = []
        while true {
            errno = 0
            guard let entry = readdir(stream) else {
                guard errno == 0 else { throw SecureDirectory.failure("read every scoped library entry") }
                break
            }
            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in pointer.withMemoryRebound(to: CChar.self, capacity: 1024) { String(cString: $0) } }
            if name != "." && name != ".." { names.append(name) }
        }
        return names.sorted()
    }
    static func snapshot(_ root: SecureDirectory) throws -> [PermissionBackup] {
        var records: [PermissionBackup] = []
        var rootInfo = stat()
        guard fstat(root.fd, &rootInfo) == 0 else { throw SecureDirectory.failure("inspect scoped root") }
        func walk(_ fd: Int32, path: String) throws {
            guard path.utf8.count < 1024, path.split(separator: "/").count <= 64 else { throw MaschineryError.invalid("Permission repair exceeds safe path depth/length") }
            var info = stat()
            guard fstat(fd, &info) == 0 else { throw SecureDirectory.failure("inspect library permission") }
            guard info.st_dev == rootInfo.st_dev, info.st_mode & S_IFMT == S_IFDIR || info.st_mode & S_IFMT == S_IFREG && info.st_nlink == 1 else { throw MaschineryError.invalid("Permission repair rejects links and special files") }
            guard records.count < 200_000 else { throw MaschineryError.invalid("Permission repair exceeds file limit") }
            records.append(PermissionBackup(path: path, mode: UInt16(info.st_mode & 0o7777), inode: info.st_ino, device: info.st_dev, owner: info.st_uid, group: info.st_gid))
            if info.st_mode & S_IFMT == S_IFDIR {
                for child in try entries(fd) {
                    var childInfo = stat()
                    guard fstatat(fd, child, &childInfo, AT_SYMLINK_NOFOLLOW) == 0,
                          childInfo.st_dev == rootInfo.st_dev,
                          childInfo.st_mode & S_IFMT == S_IFDIR || childInfo.st_mode & S_IFMT == S_IFREG && childInfo.st_nlink == 1 else { throw MaschineryError.invalid("Permission repair rejects links, special files and nested filesystems at " + (path.isEmpty ? child : path + "/" + child)) }
                    let access = childInfo.st_mode & S_IFMT == S_IFDIR ? O_RDONLY : O_EVTONLY
                    var file = openat(fd, child, access | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
                    if file < 0, errno == EACCES, childInfo.st_mode & S_IFMT == S_IFREG {
                        // Metadata-only fallback for write-only regular files. No write/truncate syscall is ever issued here.
                        file = openat(fd, child, O_WRONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
                    }
                    guard file >= 0 else { throw SecureDirectory.failure("open scoped permission target " + (path.isEmpty ? child : path + "/" + child)) }; defer { close(file) }
                    try walk(file, path: path.isEmpty ? child : path + "/" + child)
                }
            }
        }
        try walk(root.fd, path: ""); return records
    }
    static func set(_ records: [PermissionBackup], root: SecureDirectory, restore: Bool) throws {
        for record in records {
            let fd: Int32
            if record.path.isEmpty { fd = dup(root.fd) }
            else { let (parent, name) = try root.parent(record.path, create: false); fd = openat(parent.fd, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC) }
            guard fd >= 0 else { throw SecureDirectory.failure("open permission target") }; defer { close(fd) }
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_ino == record.inode, info.st_dev == record.device, info.st_mode & S_IFMT == S_IFDIR || info.st_nlink == 1 else { throw MaschineryError.invalid("Permission target identity changed; recovery retained") }
            let needed: mode_t = info.st_mode & S_IFMT == S_IFDIR ? 0o555 : 0o444
            let mode = restore ? mode_t(record.mode) : info.st_mode | needed
            if info.st_mode & 0o777 != mode & 0o777 { guard fchmod(fd, mode) == 0 else { throw SecureDirectory.failure("repair scoped library permissions") } }
        }
    }
    static func resources(_ root: SecureDirectory, product: String) throws -> [ResourceFile] {
        let (parent, name) = try root.parent("PAResources/image", create: false)
        let fd = openat(parent.fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if fd < 0 && errno == ENOENT { return [] }
        guard fd >= 0 else { throw SecureDirectory.failure("open scoped artwork") }; defer { close(fd) }
        let groups = try entries(fd).filter { ProductName.key($0) == ProductName.key(product) }
        var files: [ResourceFile] = []
        func collect(_ prefix: String, relative: String) throws {
            let directory = try root.parent(prefix + "/_", create: false).0
            for child in try entries(directory.fd) {
                let path = prefix + "/" + child, destination = relative.isEmpty ? child : relative + "/" + child
                var info = stat()
                guard fstatat(directory.fd, child, &info, AT_SYMLINK_NOFOLLOW) == 0 else { throw SecureDirectory.failure("inspect artwork") }
                if info.st_mode & S_IFMT == S_IFDIR { try collect(path, relative: destination) }
                else if let (data, _) = try root.read(path, createParents: false) { files.append(ResourceFile(path: destination, data: data)) }
            }
        }
        for group in groups { try collect("PAResources/image/" + group, relative: "") }
        guard files.reduce(0, { $0 + $1.data.count }) < 48 * 1024 * 1024 else { throw MaschineryError.invalid("Scoped artwork exceeds request budget") }
        return files
    }
}
