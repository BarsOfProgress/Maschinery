import Foundation
import Security
import Darwin

/// Installer-approved identities. This is configuration, never authority supplied by an XPC request.
public struct InstalledHelperTrust: Codable, Sendable {
    public let version: Int
    public let appHashes: [String]
    public let helperHashes: [String]
    public let setupHashes: [String]
    public init(version: Int, appHashes: [String], helperHashes: [String], setupHashes: [String]) {
        self.version = version; self.appHashes = appHashes
        self.helperHashes = helperHashes; self.setupHashes = setupHashes
    }
    public static let directory = "/Library/Application Support/Maschinery/InstalledHelper"
    public static let path = directory + "/trust.json"

    public func requirement(identifier: String) throws -> String {
        guard version == 1 else { throw MaschineryError.invalid("Unsupported installed helper configuration. Reinstall Maschinery.") }
        let hashes: [String]
        switch identifier {
        case HelperIdentity.app: hashes = appHashes
        case HelperIdentity.service: hashes = helperHashes
        case HelperIdentity.setup: hashes = setupHashes
        default: throw MaschineryError.invalid("Unknown helper peer identifier")
        }
        guard !hashes.isEmpty, hashes.count <= 8,
              hashes.allSatisfy({ $0.range(of: "^[a-f0-9]{40}$", options: .regularExpression) != nil }) else {
            throw MaschineryError.invalid("Invalid installed helper identities. Reinstall Maschinery.")
        }
        return "identifier \"\(identifier)\" and (" + hashes.map { "cdhash H\"\($0)\"" }.joined(separator: " or ") + ")"
    }

    public static var isPresent: Bool {
        var metadata = stat()
        return lstat(path, &metadata) == 0
    }

    public static func load() throws -> Self {
        try load(from: URL(fileURLWithPath: path), owner: 0)
    }

    // The injectable owner/path are internal so tests can exercise the filesystem checks
    // without root. Production callers always use the fixed path and owner above.
    static func load(from url: URL, owner: uid_t) throws -> Self {
        // Pin every component with openat: no symlink traversal, including the final file.
        var descriptor = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { throw MaschineryError.invalid("Cannot open helper trust root") }
        defer { close(descriptor) }
        let components = url.path.split(separator: "/").map(String.init)
        for (index, component) in components.enumerated() {
            let last = index == components.count - 1
            let next = openat(descriptor, component, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | (last ? O_NONBLOCK : O_DIRECTORY))
            guard next >= 0 else { throw MaschineryError.invalid("Cannot read protected helper configuration. Reinstall Maschinery.") }
            close(descriptor); descriptor = next
            var metadata = stat()
            guard fstat(descriptor, &metadata) == 0, (metadata.st_uid == owner || (!last && metadata.st_uid == 0)),
                  metadata.st_mode & 0o022 == 0,
                  (metadata.st_mode & S_IFMT) == (last ? S_IFREG : S_IFDIR),
                  !last || (metadata.st_nlink == 1 && metadata.st_size > 0 && metadata.st_size <= 8192) else {
                throw MaschineryError.invalid("Helper configuration must be root-owned and protected from modification.")
            }
            // ACL write grants must not undermine POSIX ownership checks.
            if let acl = acl_get_fd_np(descriptor, ACL_TYPE_EXTENDED) {
                defer { acl_free(UnsafeMutableRawPointer(acl)) }
                var entry: acl_entry_t?
                var result = acl_get_entry(acl, Int32(ACL_FIRST_ENTRY.rawValue), &entry)
                while result == 0, let current = entry {
                    var tag = ACL_UNDEFINED_TAG
                    guard acl_get_tag_type(current, &tag) == 0, tag == ACL_EXTENDED_DENY else {
                        throw MaschineryError.invalid("Helper configuration has an unexpected ACL grant. Reinstall Maschinery.")
                    }
                    result = acl_get_entry(acl, Int32(ACL_NEXT_ENTRY.rawValue), &entry)
                }
            } else if errno != ENOENT && errno != ENOTSUP {
                throw MaschineryError.invalid("Cannot validate helper configuration permissions")
            }
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        let data = try handle.read(upToCount: 8193) ?? Data()
        guard data.count <= 8192 else { throw MaschineryError.invalid("Helper configuration exceeds limit") }
        let trust = try JSONDecoder().decode(Self.self, from: data)
        _ = try trust.requirement(identifier: HelperIdentity.app)
        _ = try trust.requirement(identifier: HelperIdentity.service)
        _ = try trust.requirement(identifier: HelperIdentity.setup)
        return trust
    }

    public func validateCurrentApp() throws { try validateCurrentExecutable(identifier: HelperIdentity.app) }

    public func validateCurrentExecutable(identifier: String) throws {
        var code: SecCode?
        var requirement: SecRequirement?
        let expression = try self.requirement(identifier: identifier)
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecRequirementCreateWithString(expression as CFString, [], &requirement) == errSecSuccess,
              let requirement, SecCodeCheckValidity(code, [], requirement) == errSecSuccess else {
            throw MaschineryError.unavailable("This app does not match the installed helper. Quit Maschinery and install its matching package.")
        }
    }
}
