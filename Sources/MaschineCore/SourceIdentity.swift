import Foundation
import CryptoKit
import Darwin
public enum SourceIdentity {
    public static func capture(_ root: URL) throws -> String {
        var hash = SHA256()
        try SafeTree.walk(root, includeHidden: true) { url in
            var info = stat()
            guard lstat(url.path, &info) == 0 else { throw SecureDirectory.failure("inspect source identity") }
            let relative = String(url.path.dropFirst(root.path.count))
            let value = "\(relative)|\(info.st_dev)|\(info.st_ino)|\(info.st_size)|\(info.st_mtimespec.tv_sec)|\(info.st_mtimespec.tv_nsec)|\(info.st_mode)\n"
            hash.update(data: Data(value.utf8)); return true
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
