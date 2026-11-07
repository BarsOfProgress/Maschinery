import Foundation
import Darwin

public struct PermissionRepairRequest: Codable, Sendable, Equatable {
    public let transaction: UUID
    public let product: String
    public let contentPath: String
    public let inode: UInt64
    public let device: Int32
    public init(transaction: UUID = UUID(), product: String, contentPath: String, inode: UInt64, device: Int32) {
        self.transaction = transaction; self.product = product; self.contentPath = contentPath; self.inode = inode; self.device = device
    }
    public static func capture(product: String, content: URL) throws -> Self {
        let path = try ExpansionPermissionScope.canonical(content)
        let parent = try SecureDirectory(root: path.deletingLastPathComponent(), create: false)
        var info = stat()
        guard fstatat(parent.fd, path.lastPathComponent, &info, AT_SYMLINK_NOFOLLOW) == 0, info.st_mode & S_IFMT == S_IFDIR else {
            throw MaschineryError.invalid("Permission repair target is unavailable or is not a real directory: " + path.path)
        }
        try RegistrationValidation.product(product)
        return Self(product: product, contentPath: path.path, inode: info.st_ino, device: info.st_dev)
    }
}

/// Reads actual product preference records. This is evidence, never a write API.
/// The same ContentDir decoder as Library discovery handles POSIX and HFS paths.
enum NIContentRegistration {
    static func paths(product: String, preferences: SecureDirectory) throws -> [URL] {
        let prefix = "com.native-instruments."
        let files = try SharedPermissions.entries(preferences.fd).filter {
            $0.hasPrefix(prefix) && $0.hasSuffix(".plist") &&
            ProductName.key(String($0.dropFirst(prefix.count).dropLast(6))) == ProductName.key(product)
        }
        return try files.compactMap { file -> URL? in
            guard let (data, _) = try preferences.read(file, createParents: false),
                  let values = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
                throw MaschineryError.invalid("Cannot safely read NI preference \(file). The registration was left unchanged.")
            }
            guard let raw = values["ContentDir"] else { return nil }
            if let value = raw as? String, value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return nil }
            guard let value = raw as? String, let url = ExistingLibraryService.contentURL(value) else {
                throw MaschineryError.invalid("Cannot safely interpret NI ContentDir in \(file). The registration was left unchanged.")
            }
            return try ExpansionPermissionScope.canonical(url)
        }
    }
    static func jsonPaths(product: String, directory: SecureDirectory) throws -> [URL] {
        let files = try SharedPermissions.entries(directory.fd).filter {
            $0.hasSuffix(".json") && ProductName.key(String($0.dropLast(5))) == ProductName.key(product)
        }
        return try files.compactMap { file -> URL? in
            guard let (data, _) = try directory.read(file, maximum: 1024 * 1024, createParents: false),
                  let values = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw MaschineryError.invalid("Cannot safely read existing NI installed-products record \(file). It was left unchanged.")
            }
            guard let raw = values["ContentDir"] else { return nil }
            if let value = raw as? String, value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return nil }
            guard let value = raw as? String, let path = ExistingLibraryService.contentURL(value) else {
                throw MaschineryError.invalid("Invalid ContentDir in existing NI JSON record \(file). It was left unchanged.")
            }
            return try ExpansionPermissionScope.canonical(path)
        }
    }

}

enum ExpansionPermissionScope {
    static func canonical(_ url: URL) throws -> URL {
        guard url.isFileURL else { throw MaschineryError.invalid("Permission repair requires a local filesystem directory") }
        let path = url.standardizedFileURL
        try RegistrationValidation.content(path.path)
        try SafeTree.validate(path) // reject links BEFORE resolving them
        let canonical = path.resolvingSymlinksInPath().standardizedFileURL
        try RegistrationValidation.content(canonical.path); try SafeTree.validate(canonical)
        return canonical
    }
    static func open(_ request: PermissionRepairRequest, preferences: URL?, installedProducts: URL? = nil, user: uid_t) throws -> SecureDirectory {
        try RegistrationValidation.product(request.product)
        let path = try canonical(URL(fileURLWithPath: request.contentPath))
        guard path.path == request.contentPath, !["niresources", "maschinery"].contains(ProductName.key(request.product)),
              !path.lastPathComponent.hasPrefix(".") else { throw MaschineryError.invalid("Unsafe permission repair scope") }
        let root = try SecureDirectory(root: path, create: false)
        var info = stat()
        guard fstat(root.fd, &info) == 0, info.st_ino == request.inode, info.st_dev == request.device,
              info.st_uid == user || info.st_uid == 0 else { throw MaschineryError.invalid("Expansion directory identity or ownership changed. Refresh Libraries before repairing permissions.") }
        var matchesRegistration = false
        var registered: [URL] = []
        if let preferences, FileManager.default.fileExists(atPath: preferences.path) {
            registered += try NIContentRegistration.paths(product: request.product, preferences: SecureDirectory(root: preferences, create: false))
        }
        if let installedProducts, FileManager.default.fileExists(atPath: installedProducts.path) {
            registered += try NIContentRegistration.jsonPaths(product: request.product, directory: SecureDirectory(root: installedProducts, create: false))
        }
        if !registered.isEmpty {
            guard registered.allSatisfy({ registeredPath in
                guard let directory = try? SecureDirectory(root: registeredPath, create: false) else { return false }
                var other = stat()
                return fstat(directory.fd, &other) == 0 && other.st_ino == info.st_ino && other.st_dev == info.st_dev
            }) else {
                throw MaschineryError.invalid("Permission repair refused: NI ContentDir records resolve to \(registered.map(\.path).joined(separator: ", ")), but the selected expansion is \(path.path). Refresh Libraries or locate the correct existing content. No registration was changed.")
            }
            matchesRegistration = true
        }
        // Directory names alone and an empty PAResources folder are insufficient.
        // Require native Maschine content plus independent product evidence when
        // registration is absent. Every evidence read is descriptor-relative.
        var hasPreset = false, inspected = 0
        func findPreset(_ fd: Int32, depth: Int) throws {
            guard depth <= 16 else { throw MaschineryError.invalid("Expansion evidence nesting exceeds safety limit") }
            for name in try SharedPermissions.entries(fd) {
                inspected += 1
                guard inspected <= 200_000 else { throw MaschineryError.invalid("Expansion evidence exceeds the file safety limit") }
                if hasPreset { return }
                var entry = stat()
                guard fstatat(fd, name, &entry, AT_SYMLINK_NOFOLLOW) == 0 else { throw SecureDirectory.failure("inspect expansion evidence") }
                guard entry.st_dev == info.st_dev, entry.st_mode & S_IFMT != S_IFLNK else { throw MaschineryError.invalid("Expansion evidence contains a link or nested filesystem") }
                if entry.st_mode & S_IFMT == S_IFDIR {
                    let child = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                    guard child >= 0 else { throw SecureDirectory.failure("read expansion evidence; enable the helper if access is denied") }
                    defer { close(child) }; try findPreset(child, depth: depth + 1)
                } else if entry.st_mode & S_IFMT == S_IFREG, entry.st_nlink == 1, entry.st_size > 0,
                          ["mxgrp", "mxsnd"].contains(URL(fileURLWithPath: name).pathExtension.lowercased()) { hasPreset = true }
            }
        }
        for name in ["Groups", "Sounds"] where !hasPreset {
            let fd = openat(root.fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            if fd < 0 && errno == ENOENT { continue }
            guard fd >= 0 else { throw SecureDirectory.failure("verify Maschine Groups/Sounds") }
            defer { close(fd) }; try findPreset(fd, depth: 0)
        }
        var hasProductResources = false
        var marker = stat()
        if fstatat(root.fd, "PAResources", &marker, AT_SYMLINK_NOFOLLOW) == 0 {
            let (parent, name) = try root.parent("PAResources/image", create: false)
            let fd = openat(parent.fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            if fd >= 0 {
                defer { close(fd) }
                for group in try SharedPermissions.entries(fd) where ProductName.key(group) == ProductName.key(request.product) {
                    let child = openat(fd, group, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                    guard child >= 0 else { throw SecureDirectory.failure("verify product artwork directory") }
                    defer { close(child) }
                    hasProductResources = try SharedPermissions.entries(child).contains { name in
                        var entry = stat()
                        return fstatat(child, name, &entry, AT_SYMLINK_NOFOLLOW) == 0 && entry.st_mode & S_IFMT == S_IFREG && entry.st_nlink == 1 && entry.st_size > 0 && ArtworkService.extensions.contains(URL(fileURLWithPath: name).pathExtension.lowercased())
                    }
                }
            } else if errno != ENOENT { throw SecureDirectory.failure("verify PAResources/image") }
        }
        let named = ProductName.key(path.lastPathComponent) == ProductName.key(request.product)
        guard hasPreset, (matchesRegistration && (named || hasProductResources)) || (named && hasProductResources) else {
            throw MaschineryError.invalid("Cannot verify \(request.product) as an installed Maschine expansion at \(path.path). Expected native Groups/Sounds presets and matching product resources or a matching existing ContentDir. No permissions or registrations were changed.")
        }
        return root
    }
}

struct PermissionRepairJournal: Codable {
    let request: PermissionRepairRequest
    let user: uid_t
    var phase: RegistrationPhase
    let records: [PermissionBackup]
}

/// Synchronous filesystem engine, serialized by RegistrationEngine in the helper.
/// It never calls the registration writer or opens any NI record for writing.
struct PermissionRepairEngine {
    let root: URL
    let preferences: URL?
    var installedProducts: URL? = nil
    var beforeChange: (@Sendable (String) throws -> Void)? = nil
    private func file(_ id: UUID) -> String { id.uuidString + ".json" }
    private func directory(create: Bool) throws -> SecureDirectory {
        let directory = try SecureDirectory(root: root, create: create)
        if geteuid() == 0 {
            var info = stat()
            guard fstat(directory.fd, &info) == 0, info.st_uid == 0, info.st_mode & 0o022 == 0 else {
                throw MaschineryError.invalid("Permission-repair journal must be root-owned and not writable by other users")
            }
        }
        return directory
    }
    func load(_ id: UUID) throws -> PermissionRepairJournal? {
        guard FileManager.default.fileExists(atPath: root.path) else { return nil }
        guard let (data, _) = try directory(create: false).read(file(id), maximum: 64 * 1024 * 1024, createParents: false) else { return nil }
        return try JSONDecoder().decode(PermissionRepairJournal.self, from: data)
    }
    private func save(_ journal: PermissionRepairJournal) throws {
        try directory(create: true).write(file(journal.request.transaction), data: JSONEncoder().encode(journal), mode: 0o600)
    }
    func authorize(_ id: UUID, user: uid_t) throws {
        if let journal = try load(id), journal.user != user { throw MaschineryError.invalid("Permission transaction belongs to a different user") }
    }
    func checkPending(product: String, contentPath: String, excluding: UUID? = nil) throws {
        guard FileManager.default.fileExists(atPath: root.path) else { return }
        for file in try SafeTree.children(root) where file.pathExtension == "json" {
            guard let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent), id != excluding,
                  let other = try load(id), [.prepared, .applied].contains(other.phase) else { continue }
            let existing = other.request.contentPath
            if ProductName.key(product) == ProductName.key(other.request.product) || existing == contentPath || existing.hasPrefix(contentPath + "/") || contentPath.hasPrefix(existing + "/") {
                throw MaschineryError.invalid("An overlapping permission repair is unfinished. Recover it before modifying this expansion.")
            }
        }
    }
    func apply(_ request: PermissionRepairRequest, user: uid_t) throws {
        if let prior = try load(request.transaction) {
            guard prior.request == request, prior.user == user else { throw MaschineryError.invalid("Permission transaction identity changed") }
            guard [.applied, .committed].contains(prior.phase) else { throw MaschineryError.invalid("Recover the unfinished permission repair before retrying") }
            try verify(request); return
        }
        try checkPending(product: request.product, contentPath: request.contentPath, excluding: request.transaction)
        let directory = try ExpansionPermissionScope.open(request, preferences: preferences, installedProducts: installedProducts, user: user)
        let records = try SharedPermissions.snapshot(directory)
        try ScopedPermissionModes.validate(records, root: directory, user: user)
        var journal = PermissionRepairJournal(request: request, user: user, phase: .prepared, records: records)
        try save(journal)
        do {
            try ScopedPermissionModes.set(records, root: directory, user: user, restore: false, beforeChange: beforeChange)
            try verifyFiles(journal, root: directory)
            journal.phase = .applied; try save(journal)
        } catch {
            do { try rollback(request.transaction) }
            catch { throw MaschineryError.invalid("Permission repair failed; rollback needs recovery for \(request.product), transaction \(request.transaction): \(error.localizedDescription)") }
            throw error
        }
    }
    private func pinned(_ request: PermissionRepairRequest) throws -> SecureDirectory {
        let path = try ExpansionPermissionScope.canonical(URL(fileURLWithPath: request.contentPath))
        let directory = try SecureDirectory(root: path, create: false)
        var info = stat()
        guard fstat(directory.fd, &info) == 0, info.st_ino == request.inode, info.st_dev == request.device else { throw MaschineryError.invalid("Permission repair root changed; recovery data retained") }
        return directory
    }
    private func verifyFiles(_ journal: PermissionRepairJournal, root: SecureDirectory) throws {
        let current = try SharedPermissions.snapshot(root)
        guard current.count == journal.records.count else { throw MaschineryError.invalid("Expansion contents changed during permission repair") }
        let expected = Dictionary(uniqueKeysWithValues: journal.records.map { ($0.path, $0) })
        for entry in current {
            guard let old = expected[entry.path], old.inode == entry.inode, old.device == entry.device else { throw MaschineryError.invalid("Expansion contents changed during permission repair") }
        }
        try ScopedPermissionModes.verify(journal.records, root: root, user: journal.user)
    }
    func verify(_ request: PermissionRepairRequest) throws {
        guard let journal = try load(request.transaction), journal.request == request, [.prepared, .applied, .committed].contains(journal.phase) else { throw MaschineryError.invalid("Permission repair receipt is missing or changed") }
        try verifyFiles(journal, root: pinned(request))
    }
    func finish(_ id: UUID) throws {
        guard var journal = try load(id), [.applied, .committed].contains(journal.phase) else { throw MaschineryError.invalid("Cannot commit an unfinished permission repair") }
        try verify(journal.request); journal.phase = .committed; try save(journal)
    }
    func rollback(_ id: UUID) throws {
        guard var journal = try load(id), journal.phase != .rolledBack else { return }
        guard journal.phase != .committed else { throw MaschineryError.invalid("Committed permission repair cannot be rolled back") }
        try ScopedPermissionModes.set(journal.records, root: pinned(journal.request), user: journal.user, restore: true)
        journal.phase = .rolledBack; try save(journal)
    }
}

enum ScopedPermissionModes {
    static func descriptor(_ record: PermissionBackup, root: SecureDirectory) throws -> Int32 {
        let fd: Int32
        if record.path.isEmpty { fd = dup(root.fd) }
        else {
            let (parent, name) = try root.parent(record.path, create: false)
            var info = stat()
            guard fstatat(parent.fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { throw SecureDirectory.failure("inspect permission target") }
            let access = info.st_mode & S_IFMT == S_IFDIR ? O_RDONLY : O_EVTONLY
            let opened = openat(parent.fd, name, access | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            if opened < 0, errno == EACCES, info.st_mode & S_IFMT == S_IFREG {
                fd = openat(parent.fd, name, O_WRONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            } else { fd = opened }
        }
        guard fd >= 0 else { throw SecureDirectory.failure("open verified permission target") }
        var info = stat(), rootInfo = stat()
        guard fstat(root.fd, &rootInfo) == 0, fstat(fd, &info) == 0, info.st_ino == record.inode, info.st_dev == record.device,
              info.st_dev == rootInfo.st_dev,
              record.owner.map({ $0 == info.st_uid }) ?? true,
              record.group.map({ $0 == info.st_gid }) ?? true,
              info.st_mode & S_IFMT == S_IFDIR || info.st_mode & S_IFMT == S_IFREG && info.st_nlink == 1 else {
            close(fd); throw MaschineryError.invalid("Permission target changed or escaped the verified expansion")
        }
        return fd
    }
    static func groups(for user: uid_t) throws -> Set<gid_t> {
        guard let record = getpwuid(user) else { throw MaschineryError.invalid("Cannot resolve the requesting user’s group membership") }
        let name = String(cString: record.pointee.pw_name), primary = Int32(bitPattern: record.pointee.pw_gid)
        var count: Int32 = 32, groups = [Int32](repeating: 0, count: 32)
        if getgrouplist(name, primary, &groups, &count) < 0 {
            guard count > 0, count <= 1024 else { throw MaschineryError.invalid("User group membership exceeds safety limits") }
            groups = [Int32](repeating: 0, count: Int(count))
            guard getgrouplist(name, primary, &groups, &count) >= 0 else { throw MaschineryError.invalid("Cannot verify the requesting user’s groups") }
        }
        return Set(groups.prefix(Int(count)).map { gid_t(bitPattern: $0) })
    }
    static func required(_ info: stat, user: uid_t, groups: Set<gid_t>) throws -> mode_t {
        guard info.st_uid == user || info.st_uid == 0 else { throw MaschineryError.invalid("Expansion contains another user’s files; permission repair was refused") }
        let directory = info.st_mode & S_IFMT == S_IFDIR
        // Add only read/traversal for the POSIX class that actually applies to
        // the caller; never add write access or regular-file execute access.
        if info.st_uid == user { return directory ? 0o500 : 0o400 }
        if groups.contains(info.st_gid) { return directory ? 0o050 : 0o040 }
        return directory ? 0o005 : 0o004
    }
    static func validateACL(_ fd: Int32, path: String, directory: Bool) throws {
        guard let acl = acl_get_fd_np(fd, ACL_TYPE_EXTENDED) else {
            if errno == ENOATTR || errno == ENOTSUP { return }
            // Darwin may report an absent FILESEC_ACL property as ENOENT.
            // Distinguish that from a deleted/unavailable file using the pinned fd.
            if errno == ENOENT {
                var info = stat()
                if fstat(fd, &info) == 0 && info.st_nlink > 0 { return }
            }
            throw SecureDirectory.failure("inspect expansion ACL at " + path)
        }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        var entry: acl_entry_t?
        var index = Int32(ACL_FIRST_ENTRY.rawValue)
        while acl_get_entry(acl, index, &entry) == 0, let entry {
            index = Int32(ACL_NEXT_ENTRY.rawValue)
            var tag = ACL_UNDEFINED_TAG
            var permissions: acl_permset_t?
            guard acl_get_tag_type(entry, &tag) == 0, acl_get_permset(entry, &permissions) == 0, let permissions else {
                throw MaschineryError.invalid("Cannot verify the expansion’s access-control entries")
            }
            if tag == ACL_EXTENDED_DENY && (acl_get_perm_np(permissions, ACL_READ_DATA) == 1 || (directory && acl_get_perm_np(permissions, ACL_EXECUTE) == 1)) {
                throw MaschineryError.invalid("An explicit ACL denies reading/traversal at " + (path.isEmpty ? "expansion root" : path) + ". Permissions were not broadened; review this ACL in Finder or with your administrator.")
            }
        }
    }
    static func validate(_ records: [PermissionBackup], root: SecureDirectory, user: uid_t) throws {
        let groups = try groups(for: user)
        for record in records {
            let fd = try descriptor(record, root: root); defer { close(fd) }
            var info = stat(); guard fstat(fd, &info) == 0 else { throw SecureDirectory.failure("inspect permission owner") }
            _ = try required(info, user: user, groups: groups)
            try validateACL(fd, path: record.path, directory: info.st_mode & S_IFMT == S_IFDIR)
            guard info.st_flags & UInt32(UF_IMMUTABLE | SF_IMMUTABLE | UF_APPEND | SF_APPEND) == 0 else { throw MaschineryError.invalid("Expansion contains locked/immutable files at " + record.path + ". Unlock the specific file or volume before repairing permissions.") }
            guard info.st_mode & S_IFMT != S_IFREG || info.st_mode & 0o6000 == 0 else { throw MaschineryError.invalid("Permission repair refuses set-ID executables inside an expansion") }
        }
    }
    static func set(_ records: [PermissionBackup], root: SecureDirectory, user: uid_t, restore: Bool, beforeChange: (@Sendable (String) throws -> Void)? = nil) throws {
        let groups = try groups(for: user)
        let ordered = restore ? Array(records.reversed()) : records
        for record in ordered {
            let fd = try descriptor(record, root: root); defer { close(fd) }
            var info = stat(); guard fstat(fd, &info) == 0 else { throw SecureDirectory.failure("inspect permission mode") }
            let mode = restore ? mode_t(record.mode) : info.st_mode | (try required(info, user: user, groups: groups))
            if info.st_mode & 0o7777 != mode & 0o7777 {
                try beforeChange?(record.path)
                guard fchmod(fd, mode & 0o7777) == 0 else { throw SecureDirectory.failure("repair permissions at " + (record.path.isEmpty ? "expansion root" : record.path)) }
            }
        }
    }
    static func verify(_ records: [PermissionBackup], root: SecureDirectory, user: uid_t) throws {
        let groups = try groups(for: user)
        for record in records {
            let fd = try descriptor(record, root: root); defer { close(fd) }
            var info = stat(); guard fstat(fd, &info) == 0 else { throw SecureDirectory.failure("verify permission mode") }
            let needed = try required(info, user: user, groups: groups)
            guard info.st_mode & needed == needed else { throw MaschineryError.invalid("Read/traversal permission verification failed at " + record.path) }
        }
    }
}
