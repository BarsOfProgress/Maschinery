import Foundation
import Darwin

public enum AnalysisRecovery {
    static var root: URL { FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Maschine Machine/Analysis") }
    public static func clean() throws {
        guard FileManager.default.fileExists(atPath: root.path) else { return }
        try SafeTree.validate(root)
        for workspace in try SafeTree.children(root) where UUID(uuidString: workspace.lastPathComponent) != nil {
            let marker = workspace.appendingPathComponent(".owner-pid")
            guard let data = try? Data(contentsOf: marker), let text = String(data: data, encoding: .utf8), let pid = Int32(text) else { continue }
            if kill(pid, 0) != 0 && errno == ESRCH { try FileManager.default.removeItem(at: workspace) }
        }
    }
}
