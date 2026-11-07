import SwiftUI
import AppKit
import MaschineryCore
struct LibrariesView: View {
    @EnvironmentObject var model: AppModel
    @State private var selected: String?
    @State private var grid = true
    @State private var query = ""
    @State private var filter: LibraryFilter = .all
    @State private var sort: LibrarySort = .ascending
    private var entries: [LibraryCatalogueEntry] { model.libraryEntries }
    private var filtered: [LibraryCatalogueEntry] { CatalogueMatching.filter(entries, query: query, filter: filter, sort: sort) }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("YOUR LIBRARIES").font(.system(size: 18, weight: .bold)).tracking(1)
                Spacer()
                Toggle("Grid", isOn: $grid).toggleStyle(.switch)
                Button("Refresh") { model.refreshCatalogue() }.disabled(model.refreshingCatalogue || model.offline)
            }
            collectionSummary
            HStack {
                Picker("Show libraries", selection: $filter) {
                    ForEach(LibraryFilter.allCases, id: \.self) { Text($0.rawValue) }
                }.pickerStyle(.segmented).frame(maxWidth: 300)
                Spacer()
                Picker("Sort libraries", selection: $sort) {
                    ForEach(LibrarySort.allCases, id: \.self) { Text($0.rawValue) }
                }.labelsHidden().frame(width: 140)
            }
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search libraries", text: $query).textFieldStyle(.plain)
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).accessibilityLabel("Clear library search")
                }
                Text("\(filtered.count) of \(entries.count)").font(.caption).foregroundStyle(.secondary)
            }.padding(10).background(Color(white: 0.09))
            if model.auditing { HStack { ProgressView().controlSize(.small); Text(model.libraryRecordsTotal > 0 ? "Checking NI registrations · \(model.libraryRecordsChecked) of \(model.libraryRecordsTotal) · \(model.libraries.count) expansions found" : "Preparing library scan…").font(.caption) } }
            if model.libraries.isEmpty && model.busy && !model.auditing { Text("Waiting for the current operation before scanning libraries…").font(.caption).foregroundStyle(.secondary) }
            if filtered.isEmpty && !model.auditing {
                ContentUnavailableView("No matching libraries", systemImage: "magnifyingglass", description: Text("Try another name or choose a different filter."))
            }
            ScrollView {
                LazyVGrid(columns: grid ? [GridItem(.adaptive(minimum: 170), spacing: 14, alignment: .leading)] : [GridItem(.flexible(), alignment: .leading)], alignment: .leading, spacing: grid ? 14 : 6) {
                    ForEach(filtered) { entry in
                        Button { selected = selected == entry.id ? nil : entry.id } label: {
                            Group {
                                if grid {
                                    VStack(alignment: .leading, spacing: 8) {
                                        artwork(entry).frame(height: 105).clipped()
                                        librarySummary(entry)
                                    }
                                } else {
                                    HStack(spacing: 12) {
                                        artwork(entry).frame(width: 64, height: 48).clipped()
                                        librarySummary(entry)
                                        Spacer(minLength: 0)
                                    }
                                }
                            }.frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                                .padding(grid ? 12 : 8).background(Color(white: selected == entry.id ? 0.18 : 0.09))
                        }.buttonStyle(.plain)
                    }
                }
            }
            if let entry = filtered.first(where: { $0.id == selected }) {
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text(entry.name).font(.title3.bold())
                            Spacer()
                            Button("Close", systemImage: "xmark") { selected = nil }.help("Close library details")
                        }
                        if let product = entry.product {
                            if let category = product.category { Text(category).font(.caption).foregroundStyle(.secondary) }
                            if let summary = product.summary { Text(summary).font(.caption).fixedSize(horizontal: false, vertical: true) }
                            if let date = product.releaseDate { Text("Released " + date).font(.caption).foregroundStyle(.secondary) }
                            Button("View on Native Instruments", systemImage: "arrow.up.right") { NSWorkspace.shared.open(product.productURL) }
                            if !entry.installed { Text("Missing means not detected locally; it does not indicate ownership.").font(.caption).foregroundStyle(.secondary) }
                        } else { Text(model.catalogue?.complete == true ? "Not listed in the current catalogue snapshot." : "Local library · catalogue unavailable.").font(.caption).foregroundStyle(.secondary) }
                        // Management is only ever given an existing local audit record.
                        ForEach(entry.registrations) { library in localDetails(library) }
                    }.padding(16).frame(maxWidth: .infinity, alignment: .leading).background(Color(white: 0.09))
                }.frame(maxHeight: 230)
            }
        }.padding(24)
        .task { await model.loadLibrariesIfNeeded() }
    }
    private var collectionSummary: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let catalogue = model.catalogue, catalogue.complete {
                if model.libraryScanComplete {
                    let stats = CollectionStatistics(entries: entries)
                    Text("Expansion Collection — \(stats.installed) / \(stats.total) installed (\(stats.percentage ?? 0)%)").font(.system(size: 13, weight: .semibold))
                    Text("\(stats.missing) missing · \(stats.total) catalogue expansions").font(.caption).foregroundStyle(.secondary)
                } else { Text("Expansion Collection · \(catalogue.products.count) catalogue expansions · local detection pending").font(.system(size: 13, weight: .semibold)) }
                HStack(spacing: 8) {
                    if model.refreshingCatalogue { ProgressView().controlSize(.mini) }
                    Text(model.catalogueIsBundled ? "Bundled catalogue snapshot" : "Last successful refresh").font(.caption)
                    Text(catalogue.fetchedAt, format: .dateTime.day().month().year().hour().minute()).font(.caption)
                    if model.offline { Text("· Offline").font(.caption) }
                }.foregroundStyle(.secondary)
            } else { Text("Catalogue unavailable · local libraries remain available").font(.caption).foregroundStyle(.secondary) }
            if !model.catalogueMessage.isEmpty { Text(model.catalogueMessage).font(.caption).foregroundStyle(.secondary) }
        }.help("Missing means not detected locally; ownership is not checked. Completion uses the current catalogue snapshot; unlisted local libraries do not affect the percentage. Offline or unavailable content is not counted as installed.")
    }
    private func artwork(_ entry: LibraryCatalogueEntry) -> some View {
        let local = entry.registrations.compactMap(\.artwork).first
        return ArtworkView(url: local, name: entry.name, officialURL: entry.product?.artworkURL, offline: model.offline, preserveAspect: local == nil)
    }
    private func librarySummary(_ entry: LibraryCatalogueEntry) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(entry.name).font(.system(size: 13, weight: .semibold)).lineLimit(grid ? 2 : 1).truncationMode(.tail)
            Label(entry.installed ? "Installed" : "Missing", systemImage: entry.installed ? "checkmark.circle.fill" : "circle.dashed")
                .font(.system(size: 10)).foregroundStyle(entry.installed ? Color.green : Color.secondary)
                .help("Missing means not detected locally; it does not indicate ownership.")
            if entry.unlisted { Text(model.catalogue?.complete == true ? "Not in current catalogue" : "Local library").font(.system(size: 10)).foregroundStyle(.secondary) }
            if let library = entry.registrations.first {
                let issues = library.issues.filter { $0 != .missingResources }
                if !issues.isEmpty { Text(issues.map(\.rawValue).joined(separator: " · ")).font(.system(size: 10)).foregroundStyle(library.critical ? .orange : .secondary).lineLimit(2) }
            }
        }
    }
    private func localDetails(_ library: InstalledLibrary) -> some View {
        let present = library.content != nil && !library.issues.contains(.missingContent)
        return VStack(alignment: .leading, spacing: 10) {
            Text(library.content?.path ?? "Invalid ContentDir").font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            Text("Version: \(library.version ?? "Unknown")").font(.caption).foregroundStyle(.secondary)
            Text(library.issues.isEmpty ? "All audited checks passed" : library.issues.map(\.rawValue).joined(separator: " · ")).font(.caption)
            HStack {
                Button("Reveal Registration") { NSWorkspace.shared.activateFileViewerSelecting([library.id]) }
                if present, let content = library.content { Button("Reveal Library") { NSWorkspace.shared.activateFileViewerSelecting([content]) } }
            }
            HStack {
                if present && !library.issues.isEmpty { Button("Repair…") { model.prepareRepair(library) } }
                Button("Locate Content…") { model.prepareRepair(library, locate: true) }
                if present {
                    Button("Replace XML…") { model.prepareRepair(library, xml: true) }
                    Button("Relocate…") { model.prepareRepair(library, relocate: true) }
                }
                Button("Uninstall…", role: .destructive) { model.uninstall(library) }
            }.disabled(model.busy)
        }
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
                Text("Offline Mode prevents ProductHints, catalogue and official artwork requests. Saved catalogue data, cached artwork and local libraries remain available.").font(.caption).foregroundStyle(.secondary)
                Button("Clear Metadata Cache") { Task { await model.hints.clear() } }
            }
            Section("Expansion catalogue") {
                Picker("Refresh age at launch", selection: $model.catalogueRefreshHours) {
                    Text("6 hours").tag(6.0)
                    Text("12 hours").tag(12.0)
                    Text("24 hours").tag(24.0)
                    Text("3 days").tag(72.0)
                    Text("1 week").tag(168.0)
                }
                Text("The catalogue is checked once at launch when older than this age. Further updates use Refresh. Missing means not detected locally; ownership is not checked.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Privileged helper") {
                Toggle("Ask to enable the helper at launch", isOn: $model.askToEnableHelperAtLaunch)
                HStack(spacing: 8) {
                    Circle().fill(model.helperEnabled ? Color.green : Color.red).frame(width: 8, height: 8)
                        .accessibilityHidden(true)
                    Text(model.helperEnabled ? "Privileged helper enabled" : "Privileged helper not enabled")
                }
                Button("Enable Helper…") { model.enableHelper() }
                Button("Refresh Helper Status") { model.checkHelper() }
                Button("Recover Interrupted Operations") { model.recover() }.disabled(model.busy)
                Text("macOS requests administrator approval in System Settings. The app never runs as root.").font(.caption).foregroundStyle(.secondary)
            }
            Section("About") {
                Text("Maschinery · 1.0.2")
                Text("An independent utility, not affiliated with or endorsed by Native Instruments.").font(.caption).foregroundStyle(.secondary)
                Text("Registered installation and maintenance require an Apple-signed app and approved helper. Sources stay intact until verification.").font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped).disabled(model.busy)
            .onAppear { model.checkHelper() }
    }
}

struct MaintenanceReview: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(model.relocationDestination == nil ? (model.maintenancePlan?.permissions != nil ? "REVIEW PERMISSION REPAIR" : "REVIEW REGISTRATION REPAIR") : "REVIEW RELOCATION").font(.title3.bold())
            if let plan = model.maintenancePlan {
                Text(plan.product).font(.headline)
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
