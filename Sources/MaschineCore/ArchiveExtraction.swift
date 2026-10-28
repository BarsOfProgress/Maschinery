import Foundation
import SafeArchive

public enum ArchiveExtraction {
    public static func extract(_ source: URL, into destination: URL) throws {
        try SafeTree.validate(source); try SafeTree.validate(destination); try Task.checkCancellation()
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let attrs = try FileManager.default.attributesOfFileSystem(forPath: destination.path)
        let available = (attrs[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
        guard available > 0 else { throw MachineError.invalid("Cannot determine temporary workspace disk budget") }
        var error = [CChar](repeating: 0, count: 1024)
        let success = mm_extract_archive(source.path, destination.path, available, { Task.isCancelled ? 1 : 0 }, &error, error.count)
        if success == 0 { if Task.isCancelled { throw CancellationError() }; throw MachineError.invalid("Safe archive fallback: " + String(decoding: error.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)) }
        try SafeTree.walk(destination) { _ in true }
    }
}
