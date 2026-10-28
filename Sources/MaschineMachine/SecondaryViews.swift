import SwiftUI
import AppKit
import MaschineCore
struct LibrariesView: View {
    @EnvironmentObject var model: AppModel
    @State private var selected: URL?
    @State private var grid = true
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack { Text("YOUR LIBRARIES").font(.system(size: 18, weight: .bold)).tracking(1); Spacer(); Toggle("Grid", isOn: $grid).toggleStyle(.switch); Button("Refresh / Audit") { model.audit() }.disabled(model.busy) }
            Text("Audit, repair and safely relocate Native Instruments libraries.").foregroundStyle(.secondary).font(.caption)
            if model.libraries.isEmpty { ContentUnavailableView("No registered libraries found", systemImage: "square.grid.2x2", description: Text("Refresh to inspect Native Instruments registration files.")) }
            ScrollView {
                LazyVGrid(columns: grid ? [GridItem(.adaptive(minimum: 170), spacing: 14)] : [GridItem(.flexible())], spacing: 14) {
                    ForEach(model.libraries) { library in
                        Button { selected = library.id } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                ArtworkView(url: library.artwork, name: library.name).frame(height: grid ? 105 : 60)
                                Text(library.name).font(.system(size: 13, weight: .semibold))
                                Label(library.issues.isEmpty ? "Healthy" : library.issues.map(\.rawValue).joined(separator: " · "), systemImage: library.issues.isEmpty ? "checkmark.circle" : "exclamationmark.triangle").font(.system(size: 10)).foregroundStyle(library.critical ? .orange : .secondary).lineLimit(2)
                            }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(Color(white: selected == library.id ? 0.18 : 0.09))
                        }.buttonStyle(.plain)
                    }
                }
            }
            if let library = model.libraries.first(where: { $0.id == selected }) {
                Divider()
                VStack(alignment: .leading, spacing: 10) {
                    Text(library.name).font(.title3.bold())
                    Text(library.content?.path ?? "Invalid ContentDir").font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    Text("Version: \(library.version ?? "Unknown")").font(.caption).foregroundStyle(.secondary)
                    Text(library.issues.isEmpty ? "All audited checks passed" : library.issues.map(\.rawValue).joined(separator: " · ")).font(.caption)
                    HStack { Button("Reveal Registration") { NSWorkspace.shared.activateFileViewerSelecting([library.id]) }; if let content = library.content { Button("Reveal Library") { NSWorkspace.shared.activateFileViewerSelecting([content]) } } }
                    HStack {
                        Button("Repair…") { model.prepareRepair(library) }
                        Button("Locate Content…") { model.prepareRepair(library, locate: true) }
                        Button("Replace XML…") { model.prepareRepair(library, xml: true) }
                        Button("Relocate…") { model.prepareRepair(library, relocate: true) }
                    }.disabled(model.busy)
                }.padding(16).frame(maxWidth: .infinity, alignment: .leading).background(Color(white: 0.09))
            }
        }.padding(24)
    }
}
struct LogsView: View {
    @EnvironmentObject var model: AppModel
    @State private var query = ""
    @State private var level = "All"
    var body: some View {
        VStack {
            HStack { TextField("Search log", text: $query); Picker("Level", selection: $level) { Text("All"); ForEach(LogLevel.allCases, id: \.rawValue) { Text($0.rawValue) } }.frame(width: 160); Button("Copy Log") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(model.logText, forType: .string) }; Button("Save Log…") { model.saveLog() }; Button("Reveal Log") { Task { let url = await model.log.fileURL; NSWorkspace.shared.activateFileViewerSelecting([url]) } } }
            ScrollView { LazyVStack(alignment: .leading, spacing: 8) { ForEach(model.logs.filter { (level == "All" || $0.level.rawValue == level) && (query.isEmpty || $0.message.localizedCaseInsensitiveContains(query)) }) { entry in
                HStack(alignment: .top) { Text(entry.date.formatted(date: .omitted, time: .standard)).foregroundStyle(.secondary); Text(entry.level.rawValue.uppercased()).frame(width: 66, alignment: .leading); Text(entry.message).textSelection(.enabled) }.font(.system(size: 11, design: .monospaced)).frame(maxWidth: .infinity, alignment: .leading)
            } } }.padding(.top, 16)
        }.padding(24)
    }
}
struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        Form {
            Section("Installation") {
                LabeledContent("Default destination", value: model.destination)
                Button("Choose Destination…") { model.chooseDestination() }
                Toggle("Move successfully installed sources to Trash", isOn: $model.trashSources)
                Text("A shared source stays until every dependent candidate has been selected, installed and verified. Extract Only preserves sources.").font(.caption).foregroundStyle(.secondary)
                Picker("Default conflict policy", selection: $model.defaultConflict) { ForEach(ConflictPolicy.allCases, id: \.rawValue) { Text($0.rawValue.capitalized) } }
                Button("Apply policy to queue") { for i in model.candidates.indices { model.candidates[i].policy = ConflictPolicy(rawValue: model.defaultConflict) ?? .ask } }
            }
            Section("Metadata") {
                Toggle("Offline Mode", isOn: $model.offline)
                Text("Offline Mode prevents ProductHints requests during analysis. Embedded and imported XML remain available.").font(.caption).foregroundStyle(.secondary)
                Button("Clear Metadata Cache") { Task { await model.hints.clear() } }
            }
            Section("Privileged helper") {
                Text(model.helperStatus).font(.caption).textSelection(.enabled)
                Button("Enable Helper…") { model.enableHelper() }
                Button("Refresh Helper Status") { model.checkHelper() }
                Button("Recover Interrupted Operations") { model.recover() }.disabled(model.busy)
                Text("macOS requests administrator approval in System Settings. The app never runs as root.").font(.caption).foregroundStyle(.secondary)
            }
            Section("About") {
                Text("Maschine Machine · Development 1.0")
                Text("An independent utility, not affiliated with or endorsed by Native Instruments.").font(.caption).foregroundStyle(.secondary)
                Text("Registered installation and maintenance require an Apple-signed app and approved helper. Sources stay intact until verification.").font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped).disabled(model.busy)
    }
}

struct MaintenanceReview: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(model.relocationDestination == nil ? "REVIEW REPAIR" : "REVIEW RELOCATION").font(.title3.bold())
            if let plan = model.maintenancePlan {
                Text(plan.request.product).font(.headline)
                if let destination = model.relocationDestination {
                    Text("Copy and verify: " + plan.content.path + " → " + destination.path).font(.caption).textSelection(.enabled)
                    Text("Update registration only after the copy passes verification.").font(.caption)
                    Toggle("Move old content to Trash after verified relocation", isOn: $model.trashRelocated)
                } else { ForEach(plan.changes, id: \.self) { Label($0, systemImage: "checklist").font(.caption) } }
            }
            HStack { Button("Cancel") { model.showingMaintenance = false }; Spacer(); Button("Apply and Verify") { model.executeMaintenance() }.buttonStyle(.borderedProminent) }
        }.padding(28).frame(width: 620)
    }
}
