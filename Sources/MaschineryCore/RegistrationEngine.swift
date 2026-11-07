import Foundation
import Darwin

public struct RegistrationLocations: Sendable {
    public let preferences: URL, serviceCenter: URL, images: URL, journal: URL
    public let installedProducts: URL?
    public static let system = RegistrationLocations(preferences: URL(fileURLWithPath: "/Library/Preferences"), serviceCenter: URL(fileURLWithPath: "/Library/Application Support/Native Instruments/Service Center"), images: URL(fileURLWithPath: "/Users/Shared/NI Resources/image"), journal: URL(fileURLWithPath: "/Library/Application Support/Maschinery/Transactions"), installedProducts: URL(fileURLWithPath: "/Users/Shared/Native Instruments/installed_products"))
    public init(preferences: URL, serviceCenter: URL, images: URL, journal: URL, installedProducts: URL? = nil) { self.preferences = preferences; self.serviceCenter = serviceCenter; self.images = images; self.journal = journal; self.installedProducts = installedProducts }
}
private struct RegistrationBackup: Codable {
    let domain: Int, path: String, data: Data?, mode: UInt16
}
private struct RegistrationJournal: Codable {
    var request: RegistrationRequest
    var phase: RegistrationPhase
    let backups: [RegistrationBackup]
    let permissions: [PermissionBackup]?
}
/// Shared by the actual daemon and isolated integration tests. The XPC API never accepts locations.
public actor RegistrationEngine: PrivilegedService {
    private let locations: RegistrationLocations
    private let permissionRepairs: PermissionRepairEngine
    public init(locations: RegistrationLocations) {
        self.locations = locations
        permissionRepairs = PermissionRepairEngine(root: locations.journal.appendingPathComponent("PermissionRepairs"), preferences: locations.preferences, installedProducts: locations.installedProducts)
    }
    public func authorizePermissionTransaction(_ id: UUID, user: uid_t) throws { try permissionRepairs.authorize(id, user: user) }
    public func repairPermissions(_ request: PermissionRepairRequest) async throws { try applyPermissionRepair(request, user: getuid()) }
    public func applyPermissionRepair(_ request: PermissionRepairRequest, user: uid_t) throws {
        try preflight()
        guard try load(request.transaction) == nil else { throw MaschineryError.invalid("Transaction ID is already used for registration") }
        for file in try SafeTree.children(locations.journal) where file.pathExtension == "json" {
            guard let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent), let other = try load(id) else { continue }
            if ProductName.key(other.request.product) == ProductName.key(request.product), [.prepared, .applied].contains(other.phase) { throw MaschineryError.invalid("Recover the unfinished product registration transaction before permission repair") }
        }
        try permissionRepairs.apply(request, user: user)
    }
    public func verifyPermissions(_ request: PermissionRepairRequest) async throws { try permissionRepairs.verify(request) }
    public func preflight() throws {
        let directory = try SecureDirectory(root: locations.journal)
        if geteuid() == 0 {
            let parent = try SecureDirectory(root: locations.journal.deletingLastPathComponent())
            var parentInfo = stat()
            guard fstat(parent.fd, &parentInfo) == 0, parentInfo.st_uid == 0, parentInfo.st_mode & 0o022 == 0 else { throw MaschineryError.invalid("Helper journal parent must be root-owned and not writable by other users") }
            var info = stat()
            guard fstat(directory.fd, &info) == 0, info.st_uid == 0, info.st_mode & 0o022 == 0 else { throw MaschineryError.invalid("Helper journal must be root-owned and not group/world writable") }
        }
    }
    private func domain(_ number: Int) throws -> SecureDirectory {
        switch number { case 0: return try SecureDirectory(root: locations.preferences); case 1: return try SecureDirectory(root: locations.serviceCenter); case 2: return try SecureDirectory(root: locations.images); default: throw MaschineryError.invalid("Invalid registration domain") }
    }
    private func file(_ id: UUID) -> String { id.uuidString + ".json" }
    private func load(_ id: UUID) throws -> RegistrationJournal? {
        guard let (data, _) = try SecureDirectory(root: locations.journal).read(file(id), maximum: 256 * 1024 * 1024) else { return nil }
        return try JSONDecoder().decode(RegistrationJournal.self, from: data)
    }
    private func save(_ journal: RegistrationJournal) throws {
        try SecureDirectory(root: locations.journal).write(file(journal.request.transaction), data: JSONEncoder().encode(journal), mode: 0o600, maximumExisting: 256 * 1024 * 1024)
    }
    private func targets(_ request: RegistrationRequest) throws -> [(Int, String, Data?)] {
        if request.uninstall == true {
            return [(0, "com.native-instruments.\(request.product).plist", nil), (1, request.product + ".xml", nil)]
        }
        var values: [String: Any] = [:]
        if let (data, _) = try domain(0).read("com.native-instruments.\(request.product).plist"),
           let existing = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] { values = existing }
        values["ContentDir"] = request.contentPath; values["ContentVersion"] = request.version
        let plist = try PropertyListSerialization.data(fromPropertyList: values, format: .xml, options: 0)
        return [(0, "com.native-instruments.\(request.product).plist", plist), (1, request.product + ".xml", request.xml)] + request.resources.map { (2, request.product + "/" + $0.path, $0.data) }
    }
    public func sharedOperation(_ action: HelperMessage.Action, request: SharedContentRequest, user: uid_t) throws {
        switch action {
        case .swapShared: try SharedContentOperations.swap(request, user: user)
        case .restoreShared: try SharedContentOperations.restore(request, user: user)
        case .cleanupShared:
            guard let journal = try load(request.transaction), journal.phase == .committed, journal.request.product == request.product, journal.request.contentPath == request.destination else { throw MaschineryError.invalid("Shared backup cannot be removed before registration commits") }
            try SharedContentOperations.cleanup(request, user: user)
        default: throw MaschineryError.invalid("Unsupported shared operation")
        }
    }
    public func phase(_ transaction: UUID) throws -> RegistrationPhase {
        if let journal = try permissionRepairs.load(transaction) { return journal.phase }
        return try load(transaction)?.phase ?? .absent
    }
    public func apply(_ request: RegistrationRequest) throws {
        try request.validate(); try preflight()
        guard !request.repairSharedPermissions else { throw MaschineryError.invalid("Use the updated independent permission-repair action; permission repair cannot be combined with registration writes") }
        try permissionRepairs.checkPending(product: request.product, contentPath: request.contentPath)
        guard try permissionRepairs.load(request.transaction) == nil else { throw MaschineryError.invalid("Transaction ID is already used for permission repair") }
        if let previous = try load(request.transaction) {
            guard previous.request.product == request.product, previous.request.contentPath == request.contentPath, previous.request.uninstall == request.uninstall else { throw MaschineryError.invalid("Transaction identity changed") }
            if previous.phase == .applied || previous.phase == .committed { try verify(request); return }
            throw MaschineryError.invalid("Transaction is already prepared or rolled back; recover it before retrying")
        }
        // Serialize conflicting product mutations across connections, including daemon restarts.
        for url in try SafeTree.children(locations.journal) where url.pathExtension == "json" {
            guard let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent), let other = try load(id) else { continue }
            if other.request.product.caseInsensitiveCompare(request.product) == .orderedSame && [.prepared, .applied].contains(other.phase) { throw MaschineryError.invalid("Product has an unfinished transaction. Recover it before retrying.") }
        }
        if request.uninstall == true {
            guard let (data, _) = try domain(0).read("com.native-instruments.\(request.product).plist"),
                  let values = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  let path = values["ContentDir"] as? String,
                  ExistingLibraryService.contentURL(path)?.standardizedFileURL.path == request.contentPath else {
                throw MaschineryError.invalid("Library registration changed. Refresh Libraries before uninstalling.")
            }
        }
        let writes = try targets(request)
        var backups: [RegistrationBackup] = []
        var total = 0
        for (number, path, _) in writes {
            let previous = try domain(number).read(path); total += previous?.0.count ?? 0
            guard total <= 64 * 1024 * 1024 else { throw MaschineryError.invalid("Registration backup exceeds safety limit") }
            backups.append(RegistrationBackup(domain: number, path: path, data: previous?.0, mode: previous?.1 ?? 0o644))
        }
        let scope = request.repairSharedPermissions ? try SharedPermissions.scope(request, preferences: domain(0)) : nil
        let permissions = try scope.map(SharedPermissions.snapshot)
        var journal = RegistrationJournal(request: request, phase: .prepared, backups: backups, permissions: permissions)
        try save(journal) // durable undo record BEFORE any system mutation
        do {
            if let scope, let permissions {
                try SharedPermissions.set(permissions, root: scope, restore: false)
                let resources = try SharedPermissions.resources(scope, product: request.product)
                let effective = RegistrationRequest(transaction: request.transaction, product: request.product, contentPath: request.contentPath, version: request.version, xml: request.xml, resources: resources, repairSharedPermissions: true)
                try effective.validate()
                // Add artwork undo records before installing recovered resources.
                var extra = journal.backups
                for resource in resources {
                    let path = request.product + "/" + resource.path
                    if !extra.contains(where: { $0.domain == 2 && $0.path == path }) {
                        let previous = try domain(2).read(path)
                        extra.append(RegistrationBackup(domain: 2, path: path, data: previous?.0, mode: previous?.1 ?? 0o644))
                    }
                }
                journal = RegistrationJournal(request: effective, phase: .prepared, backups: extra, permissions: permissions)
                try save(journal)
            }
            for (number, path, data) in try targets(journal.request) {
                if let data { try domain(number).write(path, data: data) }
                else { try domain(number).remove(path) }
            }
            try verify(request)
            journal.phase = .applied; try save(journal)
        } catch {
            do { try rollback(request.transaction) }
            catch { throw MaschineryError.invalid("Registration failed and rollback needs recovery: \(error.localizedDescription). Transaction \(request.transaction)") }
            throw error
        }
    }
    public func verify(_ request: RegistrationRequest) throws {
        try request.validate()
        let effective: RegistrationRequest
        if let journal = try load(request.transaction) { effective = journal.request } else { effective = request }
        guard effective.product == request.product, effective.contentPath == request.contentPath, effective.xml == request.xml, effective.uninstall == request.uninstall else { throw MaschineryError.invalid("Registration verification identity changed") }
        if effective.repairSharedPermissions {
            let scope = try SharedPermissions.scope(effective, preferences: domain(0))
            let current = try SharedPermissions.snapshot(scope)
            for entry in current {
                let (parent, name) = entry.path.isEmpty ? (scope, ".") : try scope.parent(entry.path, create: false)
                var info = stat()
                guard fstatat(parent.fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { throw SecureDirectory.failure("verify scoped permission") }
                let required: UInt16 = info.st_mode & S_IFMT == S_IFDIR ? 0o555 : 0o444
                guard entry.mode & required == required else { throw MaschineryError.invalid("Library read permission repair did not verify") }
            }
        }
        for (number, path, expected) in try targets(effective) {
            if expected == nil {
                guard try domain(number).read(path) == nil else { throw MaschineryError.invalid("Uninstall verification failed: " + path) }
                continue
            }
            guard let (actual, mode) = try domain(number).read(path), actual == expected, mode & 0o444 == 0o444, mode & 0o022 == 0 else { throw MaschineryError.invalid("NI registration verification failed: \(path)") }
        }
    }
    public func finish(_ transaction: UUID) throws {
        if try permissionRepairs.load(transaction) != nil { try permissionRepairs.finish(transaction); return }
        guard var journal = try load(transaction), [.applied, .committed].contains(journal.phase) else { throw MaschineryError.invalid("Cannot commit unapplied registration") }
        try verify(journal.request); journal.phase = .committed; try save(journal)
    }
    public func rollback(_ transaction: UUID) throws {
        if try permissionRepairs.load(transaction) != nil { try permissionRepairs.rollback(transaction); return }
        guard var journal = try load(transaction) else { return }
        if journal.phase == .rolledBack { return }
        guard journal.phase != .committed else { throw MaschineryError.invalid("Committed registration cannot be rolled back") }
        for backup in journal.backups.reversed() {
            if let data = backup.data { try domain(backup.domain).write(backup.path, data: data, mode: backup.mode) }
            else { try domain(backup.domain).remove(backup.path) }
        }
        if let permissions = journal.permissions {
            let root = try SharedPermissions.scope(journal.request, preferences: domain(0))
            try SharedPermissions.set(permissions, root: root, restore: true)
        }
        journal.phase = .rolledBack; try save(journal)
    }
}
