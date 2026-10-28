import SwiftUI
import AppKit
import ServiceManagement
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
    @Published var mode: OperationMode = .install
    @Published var filter = "All"
    @Published var search = ""
    @Published var sort = "Name"
    var currentItem = ""
    @AppStorage("destination") var destination = "/Users/Shared"
    @AppStorage("offline") var offline = false
    @AppStorage("trashSources") var trashSources = false
    @AppStorage("defaultConflict") var defaultConflict = ConflictPolicy.ask.rawValue
    @Published var helperStatus = "Not checked"
    @Published var maintenancePlan: RepairPlan?
    @Published var relocationDestination: URL?
    @Published var trashRelocated = false
    @Published var showingMaintenance = false
    @Published var report: BatchReport?
    let privileged = XPCPrivilegedService()
    let log = LoggingService()
    let hints = ProductHintsService()
    var sessions: [AnalysisSession] = []
    var explicit: [RegistrationMetadata] = []
    var task: Task<Void, Never>?
    var lastProgress = Date.distantPast
    var active: [ExpansionCandidate] {
        candidates.filter {
            let matches = filter == "All" || (filter == "Existing" && $0.existingPath != nil) || (filter == "Warning" && !$0.warnings.isEmpty) || $0.state.rawValue.lowercased() == filter.lowercased()
            return matches && (search.isEmpty || $0.name.localizedCaseInsensitiveContains(search))
        }.sorted {
            if sort == "Size" { return $0.size == $1.size ? $0.name < $1.name : $0.size > $1.size }
            if sort == "State" { return $0.state == $1.state ? $0.name < $1.name : $0.state.rawValue < $1.state.rawValue }
            return $0.name < $1.name
        }
    }
    func choose(folder: Bool = false, xml: Bool = false) {
        let panel = NSOpenPanel(); panel.canChooseDirectories = folder || xml; panel.canChooseFiles = !folder; panel.allowsMultipleSelection = true
        panel.prompt = xml ? "Import XML" : "Analyse"
        guard panel.runModal() == .OK else { return }
        if xml { importXML(panel.urls) } else { analyze(panel.urls) }
    }
    func chooseDestination() {
        guard !busy else { return }
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
                sessions.append(result.session)
                let existing = try await background { try ExistingLibraryService.audit() }
                for var candidate in result.candidates {
                    candidate.policy = ConflictPolicy(rawValue: defaultConflict) ?? .ask
                    if let installed = existing.first(where: { ProductName.key($0.name) == ProductName.key(candidate.name) }), let content = installed.content {
                        candidate.existingPath = content; candidate.destination = content; candidate.state = .conflict
                        candidate.warnings.append("Already registered at " + content.path)
                    }
                    if let i = candidates.firstIndex(where: { ProductName.key($0.name) == ProductName.key(candidate.name) && $0.state != .installed }) {
                        for payload in candidate.payloads where !candidates[i].payloads.contains(payload) { candidates[i].payloads.append(payload) }
                        candidates[i].sources += candidate.sources; candidates[i].size += candidate.size
                        if candidates[i].metadata == nil { candidates[i].metadata = candidate.metadata }
                        // A later drop may supply the artwork-bearing part of an existing logical expansion.
                        let payloads = candidates[i].payloads, product = candidates[i].name
                        let discovery = try await background { try ArtworkService.discover(payloads: payloads, productName: product) }
                        candidates[i].artworkDiscovery = discovery; candidates[i].artwork = discovery.selected?.url
                        if discovery.selected != nil { candidates[i].warnings.removeAll { $0 == "Artwork unavailable" } }
                        await ArtworkService.log(discovery, product: product, to: log)
                        selected.insert(candidates[i].id)
                    } else { candidates.append(candidate); selected.insert(candidate.id) }
                }
                status = "\(candidates.count) expansions analysed"
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
                            if url.pathExtension.lowercased() == "xml" { records += try MetadataXML.read(url, source: .user) }; return true
                        }
                    }; return records
                }
                explicit += records
                for i in candidates.indices {
                    switch MetadataMatchingService.match(candidates[i].name, in: explicit) {
                    case .matched(let metadata): candidates[i].metadata = metadata; candidates[i].warnings.removeAll { $0.contains("metadata") || $0.contains("XML") }
                    case .ambiguous: candidates[i].metadata = nil; candidates[i].warnings.append("Multiple explicit XML records match; resolve before Install")
                    case .unresolved: break
                    }
                }; status = "Imported \(records.count) product records"
            } catch { status = error.localizedDescription; await log.log(.error, status) }
            busy = false; await refreshLogs()
        }
    }
    func chooseXML(for id: UUID) {
        guard !busy, let i = candidates.firstIndex(where: { $0.id == id }) else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.canChooseFiles = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let records = try MetadataXML.read(url, source: .user)
            guard case .matched(let match) = MetadataMatchingService.match(candidates[i].name, in: records) else { throw MachineError.invalid("Choose a single XML record matching " + candidates[i].name) }
            candidates[i].metadata = match
            candidates[i].warnings.removeAll { $0.localizedCaseInsensitiveContains("metadata") || $0.contains("XML") }
            if candidates[i].state == .warning && candidates[i].warnings.isEmpty { candidates[i].state = .ready }
        } catch { status = error.localizedDescription }
    }
    func install() {
        guard !busy else { return }; busy = true
        let batchSelection = selected
        let queue = candidates.filter { selected.contains($0.id) && $0.state != .installed && (mode == .install || $0.state != .extracted) }, mode = mode, log = log
        let shouldTrash = trashSources && mode == .install
        task = Task {
            if mode == .install && queue.contains(where: { $0.policy != .skip }) {
                do { try await privileged.preflight() }
                catch { busy = false; status = error.localizedDescription; await log.log(.error, status); await refreshLogs(); return }
            }
            for (offset, candidate) in queue.enumerated() {
                if Task.isCancelled { break }
                guard let index = candidates.firstIndex(where: { $0.id == candidate.id }) else { continue }
                if candidate.policy == .skip { candidates[index].state = .skipped; continue }
                candidates[index].state = .installing; currentItem = "\(offset + 1) of \(queue.count) · \(candidate.name)"; status = currentItem
                do {
                    let plan = try InstallationPlanner.plan(candidate, mode: mode)
                    try await background { [self] in
                        try await InstallationService(log: log, privileged: privileged).execute(plan) { progress in
                            await self.setProgress(progress)
                        }
                    }
                    candidates[index].state = mode == .install ? .installed : .extracted
                } catch is CancellationError { candidates[index].state = .cancelled }
                catch { candidates[index].state = .failed; candidates[index].warnings.append(error.localizedDescription); await log.log(.error, "\(candidate.name): \(error.localizedDescription)") }
            }
            var cleanup: [String] = []
            if shouldTrash && !Task.isCancelled {
                let sources = SourceTrashService.eligibleSources(candidates: candidates, selected: batchSelection)
                for source in sources {
                    do {
                        try Task.checkCancellation()
                        _ = try await background { try SourceTrashService.trash(source) }
                        cleanup.append("Trashed " + source.url.lastPathComponent)
                        await log.log(.success, "Moved verified source to Trash: " + source.url.lastPathComponent)
                    } catch { cleanup.append("Preserved " + source.url.lastPathComponent + ": " + error.localizedDescription); await log.log(.warning, cleanup.last!) }
                }
            }
            report = BatchReport(candidates: candidates.filter { batchSelection.contains($0.id) }, mode: mode, cleanup: cleanup)
            busy = false; fraction = 0; status = "Batch complete · \(candidates.filter { $0.state == .installed || $0.state == .extracted }.count) verified · \(candidates.filter { $0.state == .failed }.count) failed"; await refreshLogs()
        }
    }
    func setProgress(_ progress: CopyProgress) { guard Date().timeIntervalSince(lastProgress) > 0.1 || progress.bytes == progress.total else { return }; lastProgress = Date(); fraction = progress.total > 0 ? Double(progress.bytes) / Double(progress.total) : 0; status = currentItem + " · " + progress.phase + " · " + ByteCountFormatter.string(fromByteCount: progress.bytes, countStyle: .file) + " / " + ByteCountFormatter.string(fromByteCount: progress.total, countStyle: .file); Task { await refreshLogs() } }
    func refreshLogs() async { logs = await log.snapshot() }
    func audit() {
        guard !busy else { return }; busy = true
        task = Task {
            do { libraries = try await background { try ExistingLibraryService.audit() }; status = "Audited \(libraries.count) registrations" }
            catch { status = error.localizedDescription; await log.log(.error, status) }
            busy = false; await refreshLogs()
        }
    }
    func enableHelper() {
        do { try XPCPrivilegedService.enable(); helperStatus = "Approval requested"; SMAppService.openSystemSettingsLoginItems() }
        catch { helperStatus = error.localizedDescription; if XPCPrivilegedService.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() } }
    }
    func checkHelper() { helperStatus = String(describing: XPCPrivilegedService.status) }
    func recover() {
        guard !busy else { return }; busy = true
        task = Task {
            do {
                try await background { [self] in
                    try await TransactionStore().recover(using: privileged, log: log)
                    try await RepairService(privileged: privileged, log: log).recover()
                    try await MountRecovery(log: log).recover()
                    try AnalysisRecovery.clean()
                }
                status = "Recovery check complete"
            } catch { status = "Recovery needs attention: " + error.localizedDescription; await log.log(.error, status) }
            busy = false; await refreshLogs()
        }
    }
    func prepareRepair(_ library: InstalledLibrary, locate: Bool = false, xml: Bool = false, relocate: Bool = false) {
        guard !busy else { return }
        var content: URL?
        var records = explicit
        if locate {
            let picker = NSOpenPanel(); picker.canChooseFiles = false; picker.canChooseDirectories = true
            guard picker.runModal() == .OK, let url = picker.url else { return }; content = url
        }
        if xml {
            let picker = NSOpenPanel(); picker.canChooseFiles = true; picker.canChooseDirectories = false
            guard picker.runModal() == .OK, let url = picker.url else { return }
            do { records = try MetadataXML.read(url, source: .user) }
            catch { status = error.localizedDescription; return }
        }
        var destination: URL?
        if relocate {
            let picker = NSOpenPanel(); picker.canChooseFiles = false; picker.canChooseDirectories = true; picker.canCreateDirectories = true
            guard picker.runModal() == .OK, let url = picker.url else { return }; destination = url.appendingPathComponent(library.name)
        }
        busy = true
        let chosen = content, metadata = records, target = destination, offline = offline
        task = Task {
            do {
                let plan = try await background { [self] in try await RepairService(privileged: privileged, log: log).plan(library, content: chosen, explicit: metadata, hints: hints, offline: offline) }
                maintenancePlan = plan; relocationDestination = target; trashRelocated = false; showingMaintenance = true
            } catch { status = error.localizedDescription; await log.log(.error, status) }
            busy = false; await refreshLogs()
        }
    }
    func executeMaintenance() {
        guard let plan = maintenancePlan, !busy else { return }
        showingMaintenance = false; busy = true
        let destination = relocationDestination, trash = trashRelocated
        task = Task {
            do {
                try await background { [self] in
                    if let destination {
                        try await RelocationService(privileged: privileged, log: log).relocate(plan, destination: destination, trashOld: trash) { progress in await self.setProgress(progress) }
                    } else { try await RepairService(privileged: privileged, log: log).execute(plan) }
                }
                status = destination == nil ? "Repair verified" : "Relocation verified"
                libraries = try await background { try ExistingLibraryService.audit() }
            } catch { status = error.localizedDescription; await log.log(.error, status) }
            busy = false; await refreshLogs()
        }
    }
    func retryFailed() { selected = Set(candidates.filter { $0.state == .failed || $0.state == .cancelled }.map(\.id)); install() }
    func saveReport() {
        guard let report else { return }
        let panel = NSSavePanel(); panel.nameFieldStringValue = "MaschineMachine-Report.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; try encoder.encode(report).write(to: url, options: .atomic) }
        catch { status = error.localizedDescription }
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
