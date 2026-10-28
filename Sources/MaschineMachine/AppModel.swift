import SwiftUI
import AppKit
import MaschineCore

@MainActor final class AppModel: ObservableObject {
    @Published var page = "Install"
    @Published var candidates: [ExpansionCandidate] = []
    @Published var selected = Set<UUID>()
    @Published var libraries: [InstalledLibrary] = []
    @Published var logs: [LogEntry] = []
    @Published var busy = false
    @Published var status = "Ready for your expansions"
    @Published var fraction = 0.0
    @Published var mode: OperationMode = .extract
    @Published var filter = "All"
    @Published var search = ""
    @AppStorage("destination") var destination = "/Users/Shared"
    @AppStorage("offline") var offline = false
    let log = LoggingService()
    let hints = ProductHintsService()
    var sessions: [AnalysisSession] = []
    var explicit: [RegistrationMetadata] = []
    var task: Task<Void, Never>?
    var active: [ExpansionCandidate] {
        candidates.filter { (filter == "All" || $0.state.rawValue.lowercased() == filter.lowercased()) && (search.isEmpty || $0.name.localizedCaseInsensitiveContains(search)) }.sorted { $0.name < $1.name }
    }
    func choose(folder: Bool = false, xml: Bool = false) {
        let panel = NSOpenPanel(); panel.canChooseDirectories = folder || xml; panel.canChooseFiles = !folder; panel.allowsMultipleSelection = true
        panel.prompt = xml ? "Import XML" : "Analyse"
        guard panel.runModal() == .OK else { return }
        if xml { importXML(panel.urls) } else { analyze(panel.urls) }
    }
    func chooseDestination() {
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url, url.path != "/" else { return }
        destination = url.path
        for i in candidates.indices { candidates[i].destination = url.appendingPathComponent(ProductName.display(candidates[i].name)) }
    }
    func analyze(_ urls: [URL]) {
        guard !busy else { return }; busy = true; status = "Analysing sources · collecting metadata across the batch"
        let destination = URL(fileURLWithPath: destination), explicit = explicit, offline = offline, log = log, hints = hints
        task = Task {
            do {
                let result = try await background { try await ExpansionAnalyzer(log: log, hints: hints).analyze(urls, destination: destination, explicit: explicit, offline: offline) }
                sessions.append(result.session); candidates += result.candidates; selected.formUnion(result.candidates.map(\.id)); status = "\(candidates.count) expansions analysed"
            } catch { status = error.localizedDescription; await log.log(.error, status) }
            busy = false; await refreshLogs()
        }
    }
    func importXML(_ urls: [URL]) {
        guard !busy else { return }; busy = true
        task = Task {
            do {
                let records = try await background {
                    var records: [RegistrationMetadata] = []
                    for root in urls {
                        try SafeTree.walk(root) { url in
                            if url.pathExtension.lowercased() == "xml" { records += try MetadataXML.parse(Data(contentsOf: url), source: .user) }; return true
                        }
                    }; return records
                }
                explicit += records
                for i in candidates.indices {
                    switch MetadataMatchingService.match(candidates[i].name, in: explicit) {
                    case .matched(let metadata): candidates[i].metadata = metadata; candidates[i].warnings.removeAll { $0.contains("metadata") || $0.contains("XML") }
                    case .ambiguous: candidates[i].warnings.append("Multiple explicit XML records match; resolve before Install")
                    case .unresolved: break
                    }
                }; status = "Imported \(records.count) product records"
            } catch { status = error.localizedDescription; await log.log(.error, status) }
            busy = false; await refreshLogs()
        }
    }
    func install() {
        guard !busy else { return }; busy = true
        let queue = candidates.filter { selected.contains($0.id) && $0.state != .installed }, mode = mode, log = log
        task = Task {
            for (offset, candidate) in queue.enumerated() {
                if Task.isCancelled { break }
                guard let index = candidates.firstIndex(where: { $0.id == candidate.id }) else { continue }
                if candidate.policy == .skip { candidates[index].state = .skipped; continue }
                candidates[index].state = .installing; status = "\(offset + 1) of \(queue.count) · \(candidate.name)"
                do {
                    let plan = try InstallationPlanner.plan(candidate, mode: mode)
                    try await background { [self] in
                        try await InstallationService(log: log).execute(plan) { progress in
                            await self.setProgress(progress)
                        }
                    }
                    candidates[index].state = .installed
                } catch is CancellationError { candidates[index].state = .cancelled }
                catch { candidates[index].state = .failed; candidates[index].warnings.append(error.localizedDescription); await log.log(.error, "\(candidate.name): \(error.localizedDescription)") }
            }
            busy = false; fraction = 0; status = "Batch complete · \(candidates.filter { $0.state == .installed }.count) verified · \(candidates.filter { $0.state == .failed }.count) failed"; await refreshLogs()
        }
    }
    func setProgress(_ progress: CopyProgress) { fraction = progress.total > 0 ? Double(progress.bytes) / Double(progress.total) : 0 }
    func refreshLogs() async { logs = await log.snapshot() }
    func audit() {
        guard !busy else { return }; busy = true
        task = Task {
            do { libraries = try await background { try ExistingLibraryService.audit() }; status = "Audited \(libraries.count) registrations" }
            catch { status = error.localizedDescription; await log.log(.error, status) }
            busy = false; await refreshLogs()
        }
    }
    func cancel() { task?.cancel() }
    func saveLog() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "MaschineMachine.log"
        if panel.runModal() == .OK, let url = panel.url {
            do { try logText.write(to: url, atomically: true, encoding: .utf8) } catch { status = error.localizedDescription }
        }
    }
    var logText: String { logs.map { "\($0.date.formatted()) \($0.level.rawValue.uppercased()) \($0.message)" }.joined(separator: "\n") }
}
