import SwiftUI
import AppKit
import UniformTypeIdentifiers
import ImageIO
import MaschineryCore

@main struct MaschineryApp: App {
    @StateObject private var model = AppModel()
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    var body: some Scene {
        WindowGroup {
            MainView().environmentObject(model).preferredColorScheme(.dark).frame(minWidth: 1000, minHeight: 660)
                .task { delegate.model = model; await model.start() }
                .onChange(of: model.offline) { _, _ in model.catalogueConnectivityChanged() }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in model.checkHelper() }
                .sheet(isPresented: $model.showingMaintenance) { MaintenanceReview().environmentObject(model) }
        }.windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Add Files…") { model.choose() }.keyboardShortcut("o")
                Button("Add Folder…") { model.choose(folder: true) }.keyboardShortcut("o", modifiers: [.command, .shift])
                Button("Bulk XML Import…") { model.choose(xml: true) }
            }
            CommandGroup(replacing: .appInfo) { Button("About Maschinery") {
                NSApplication.shared.orderFrontStandardAboutPanel(options: [.applicationName: "Maschinery", .applicationVersion: "1.0.5r1", .credits: NSAttributedString(string: "Independent utility. Not affiliated with or endorsed by Native Instruments.\nInstallation and maintenance use administrator-approved privileges.")])
            } }
            CommandGroup(after: .windowArrangement) { Button("Logs") { model.page = "Logs" }.keyboardShortcut("l") }
        }
        Settings { SettingsView().environmentObject(model).preferredColorScheme(.dark).padding(28).frame(width: 560) }
    }
}
@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model, model.busy else { return .terminateNow }
        let alert = NSAlert(); alert.messageText = "An operation is active"; alert.informativeText = "Continue working, or wait for safe cancellation and then quit. Verified installations remain installed."
        alert.addButton(withTitle: "Continue Operation"); alert.addButton(withTitle: "Cancel Safely and Quit")
        if alert.runModal() == .alertSecondButtonReturn {
            model.cancel()
            Task { @MainActor in
                while model.busy { try? await Task.sleep(for: .milliseconds(100)) }
                sender.reply(toApplicationShouldTerminate: true)
            }
            return .terminateLater
        }
        return .terminateCancel
    }
}
private let accent = Color(red: 0.86, green: 0.94, blue: 0.18)
private let panel = Color(white: 0.085)
struct MainView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                Text("MASCHINERY").font(.system(size: 18, weight: .black, design: .rounded)).tracking(1)
                    .lineLimit(1).minimumScaleFactor(0.9).padding(.vertical, 30)
                Text("LIBRARY MANAGEMENT").font(.system(size: 9, weight: .semibold)).tracking(2).foregroundStyle(.secondary).padding(.bottom, 32)
                ForEach([("Install", "square.and.arrow.down"), ("Libraries", "square.grid.2x2"), ("Logs", "text.alignleft"), ("Settings", "slider.horizontal.3")], id: \.0) { title, icon in
                    Button { model.page = title; if title == "Logs" { Task { await model.refreshLogs() } } } label: {
                        Label(title, systemImage: icon).font(.system(size: 13, weight: .medium)).frame(maxWidth: .infinity, alignment: .leading).padding(12).background(model.page == title ? Color(white: 0.16) : .clear).foregroundStyle(model.page == title ? accent : .secondary)
                    }.buttonStyle(.plain).padding(.bottom, 4)
                }
                Spacer()
                Text("MASCHINERY\n1.0.5r1").font(.system(size: 10)).foregroundStyle(.secondary).lineSpacing(5).padding(.bottom, 22)
            }.padding(.horizontal, 20).frame(width: 190).background(panel)
            Rectangle().fill(Color(white: 0.18)).frame(width: 1)
            VStack(spacing: 0) {
                HStack { Text(model.page.uppercased()).font(.system(size: 15, weight: .bold)).tracking(2); Spacer(); if model.offline { Label("OFFLINE", systemImage: "wifi.slash").font(.caption).foregroundStyle(accent) }; Text("MASCHINE LIBRARY ORGANIZER").font(.system(size: 9)).tracking(2).foregroundStyle(.secondary) }.padding(24)
                Divider()
                Group {
                    switch model.page {
                    case "Libraries": LibrariesView()
                    case "Logs": LogsView()
                    case "Settings": SettingsView().padding(28)
                    default: InstallView()
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                Divider()
                HStack { Circle().fill(model.busy ? accent : .gray).frame(width: 5, height: 5); Text(model.status).font(.system(size: 11)).lineLimit(2); Spacer(); if model.busy {
                    if model.auditing && model.libraryRecordsTotal == 0 {
                        ProgressView().controlSize(.small)
                    } else {
                        ProgressView(value: model.fraction).frame(width: 120)
                            .accessibilityLabel(model.auditing ? "Library scan progress" : "Operation progress")
                    }
                    Button("Cancel") { model.cancel() }
                } }.padding(12).background(panel)
            }
        }.background(Color(white: 0.035)).tint(accent)
    }
}
struct InstallView: View {
    @EnvironmentObject var model: AppModel
    @State private var targeted = false
    var body: some View {
        VStack(spacing: 18) {
            VStack(spacing: 12) {
                Image(systemName: "square.stack.3d.up").font(.system(size: 30, weight: .ultraLight)).foregroundStyle(accent)
                Text("DROP MASCHINE EXPANSIONS HERE").font(.system(size: 17, weight: .bold)).tracking(1.5)
                Text("ISO images · Installer packages · Library folders").font(.system(size: 12)).foregroundStyle(.secondary)
                HStack { Button("Add Files…") { model.choose() }; Button("Add Folder…") { model.choose(folder: true) }; Button("Bulk XML Import…") { model.choose(xml: true) } }.padding(.top, 4)
            }.frame(maxWidth: .infinity).padding(.vertical, model.candidates.isEmpty ? 55 : 24).background(targeted ? Color(white: 0.13) : panel).overlay(Rectangle().strokeBorder(targeted ? accent : Color(white: 0.22), lineWidth: 1))
                .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
                    guard !model.busy else { return false }
                    Task {
                        var urls: [URL] = []
                        for provider in providers {
                            if let url: URL = await withCheckedContinuation({ continuation in
                                _ = provider.loadObject(ofClass: URL.self) { url, _ in continuation.resume(returning: url) }
                            }) { urls.append(url) }
                        }; model.analyze(urls)
                    }; return true
                }
            HStack {
                Text("\(model.candidates.count) EXPANSIONS").font(.system(size: 11, weight: .bold)).tracking(1)
                Spacer()
                Picker("Filter", selection: $model.filter) { ForEach(["All", "Ready", "Warning", "Conflict", "Failed", "Existing", "Installed", "Extracted"], id: \.self) { Text($0) } }.frame(width: 150)
                Picker("Sort", selection: $model.sort) { ForEach(["Name", "Size", "State"], id: \.self) { Text($0) } }.frame(width: 110)
                TextField("Search expansions", text: $model.search).frame(width: 170)
            }
            if model.candidates.isEmpty {
                VStack(alignment: .leading, spacing: 14) {
                    Text("YOUR SOURCES STAY YOURS").font(.system(size: 12, weight: .bold)).tracking(1)
                    Text("Install your Maschine expansions without Native Access. Add your expansion files, choose where they go, and let Maschinery install, register and verify your libraries.").foregroundStyle(.secondary).font(.system(size: 13))
                        .lineLimit(nil).fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Label("Elevated privileges for installation are not enabled. Run the full installer, then reopen Maschinery.", systemImage: "info.circle").font(.caption).foregroundStyle(.secondary)
                }.padding(24).frame(maxWidth: .infinity, alignment: .leading).background(panel)
                Spacer()
            } else {
                ScrollView { LazyVStack(spacing: 1) { ForEach(model.active) { candidate in CandidateRow(candidate: candidate) } } }
                HStack {
                    Button("Select All") { model.selected = Set(model.candidates.map(\.id)) }; Button("None") { model.selected.removeAll() }
                    Button("Remove") { model.candidates.removeAll { model.selected.contains($0.id) }; model.selected.removeAll() }
                    Spacer()
                    Picker("Mode", selection: $model.mode) { ForEach(OperationMode.allCases, id: \.self) { Text($0.rawValue) } }.frame(width: 165)
                    Button("Start Selected") { model.install() }.buttonStyle(.borderedProminent).disabled(model.selected.isEmpty)
                }
            }
            if model.report != nil {
                HStack { Button("Save Report…") { model.saveReport() }; Button("Retry Failed") { model.retryFailed() }; Spacer(); Text(model.report!.cleanup.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
            }
            HStack { Text("DESTINATION").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary); Text(model.destination).font(.system(size: 11, design: .monospaced)).lineLimit(1); Spacer(); Button("Choose…") { model.chooseDestination() } }
        }.padding(24).disabled(model.busy)
    }
}
struct CandidateRow: View {
    @EnvironmentObject var model: AppModel
    let candidate: ExpansionCandidate
    @State private var expanded = false
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                Toggle("Select \(candidate.name)", isOn: Binding(get: { model.selected.contains(candidate.id) }, set: { if $0 { model.selected.insert(candidate.id) } else { model.selected.remove(candidate.id) } })).labelsHidden()
                ArtworkView(url: candidate.artwork, name: candidate.name).frame(width: 90, height: 58)
                VStack(alignment: .leading, spacing: 6) {
                    Text(candidate.name).font(.system(size: 14, weight: .semibold))
                    Text("Payload ✓   Metadata \(candidate.metadata == nil ? "—" : "✓")   Artwork \(candidate.artwork == nil ? "—" : "✓")").font(.system(size: 10)).foregroundStyle(.secondary)
                    Text(candidate.destination.path).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 6) { Text(candidate.state.rawValue.uppercased()).font(.system(size: 10, weight: .bold)).foregroundStyle(candidate.state == .installed ? accent : .primary); Text(ByteCountFormatter.string(fromByteCount: candidate.size, countStyle: .file)).font(.caption).foregroundStyle(.secondary) }
                Button { expanded.toggle() } label: { Image(systemName: expanded ? "chevron.up" : "chevron.down") }.buttonStyle(.plain).accessibilityLabel("Inspect \(candidate.name)")
            }
            if let existing = candidate.existingPath {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Already installed at " + existing.path).font(.caption).textSelection(.enabled)
                    HStack {
                        Button("Overwrite Installed Library") { model.overwriteExisting(candidate.id) }
                        Button("Install Elsewhere…") { model.chooseInstallDestination(candidate.id) }
                    }
                    if candidate.destination != existing {
                        Text("Registration will use the new destination. The old content files will be kept.").font(.caption).foregroundStyle(.secondary)
                    }
                    if candidate.policy == .replace {
                        Text("Overwrite selected: the destination’s entire contents will be replaced after verification.").font(.caption).foregroundStyle(.orange)
                    }
                }
            }
            if expanded {
                Divider()
                ForEach(candidate.sources) { source in Button(source.url.path) { NSWorkspace.shared.activateFileViewerSelecting([source.url]) }.buttonStyle(.link).font(.caption) }
                ForEach(Array(candidate.warnings.enumerated()), id: \.offset) { _, warning in Label(warning, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.secondary) }
                if let discovery = candidate.artworkDiscovery {
                    DisclosureGroup("Artwork diagnostics · \(discovery.consideredCount) images considered") {
                        VStack(alignment: .leading, spacing: 7) {
                            Text(discovery.selected?.url.path ?? "No artwork selected — dark placeholder").font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                            Text(discovery.selectionReason).font(.caption).foregroundStyle(.secondary)
                            ForEach(discovery.rankedCandidates) { image in
                                Text("\(image.url.lastPathComponent) · \(image.dimensions) · score \(image.score)\n" + image.reasons.joined(separator: "; ")).font(.caption).textSelection(.enabled)
                            }
                            ForEach(discovery.rejectedCandidates) { image in
                                Text("Rejected \(image.url.lastPathComponent) · \(image.dimensions): \(image.rejectionReason ?? "")").font(.caption).foregroundStyle(.secondary)
                            }
                            ForEach(discovery.warnings, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
                    }
                }
                if candidate.policy == .replace { Text("Replace swaps the entire destination. The old directory is backed up until verification, then removed.").font(.caption).foregroundStyle(.orange) }
                HStack {
                    Picker("Existing content", selection: Binding(get: { candidate.policy }, set: { policy in if let i = model.candidates.firstIndex(where: { $0.id == candidate.id }) { model.candidates[i].policy = policy } })) { ForEach(ConflictPolicy.allCases, id: \.self) { Text($0.rawValue.capitalized) } }.frame(width: 230)
                    Button("Choose XML…") { model.chooseXML(for: candidate.id) }
                    Button("Destination…") {
                        model.chooseInstallDestination(candidate.id)
                    }
                }
            }
        }.padding(14).background(panel)
    }
}
struct ArtworkView: View {
    let url: URL?; let name: String
    var officialURL: URL? = nil
    var offline = false
    var preserveAspect = false
    @State private var thumbnail: NSImage?
    @State private var showingOfficialArtwork = false
    var body: some View {
        // The background determines layout. A scaled-to-fill image must stay
        // in an overlay so its aspect ratio cannot widen a grid column.
        Color(white: 0.15).overlay {
            if let thumbnail {
                if preserveAspect || showingOfficialArtwork { Image(nsImage: thumbnail).resizable().scaledToFit() }
                else { Image(nsImage: thumbnail).resizable().scaledToFill() }
            }
            else { VStack(spacing: 6) { Image(systemName: "square.grid.4x3.fill").foregroundStyle(Color(white: 0.35)); Text(name.uppercased()).font(.system(size: 8, weight: .bold)).lineLimit(2).multilineTextAlignment(.center) }.padding(8) }
        }.clipped().accessibilityLabel("\(name) artwork")
        .task(id: "\(url?.absoluteString ?? "")|\(officialURL?.absoluteString ?? "")|\(offline)") {
            thumbnail = nil; showingOfficialArtwork = false
            if let url, let cached = await ArtworkThumbnailCache.shared.thumbnail(at: url), !Task.isCancelled {
                thumbnail = NSImage(cgImage: cached.image, size: NSSize(width: cached.image.width, height: cached.image.height))
                return
            }
            guard !Task.isCancelled, let file = await OfficialArtworkCache.shared.file(for: officialURL, offline: offline),
                  !Task.isCancelled, let cached = await ArtworkThumbnailCache.shared.thumbnail(at: file), !Task.isCancelled else { return }
            showingOfficialArtwork = true
            thumbnail = NSImage(cgImage: cached.image, size: NSSize(width: cached.image.width, height: cached.image.height))
        }
    }
}
