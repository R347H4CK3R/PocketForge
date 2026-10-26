import SwiftUI
import ZIPFoundation
import UniformTypeIdentifiers

@MainActor @Observable final class RepairWorkspace {
    var issue = ""
    var logText = ""
    var ipaName = ""
    var logName = ""
    var findings = "Import an IPA and optionally a diagnostic log. Describe what went wrong."
    var proposedFix = ""
    var sourceAvailable = false
    var repairedIPA: URL?
    var reconstructed = false
    var evidenceReport: URL?
    var evidenceStatus = "No binary analysis performed."
    var automaticStatus = "Not run"
    var sourceDiscoveryReport = "No source search performed."
    var repositoryDiscoveryReport = "Public repository search not run."
    private var archiveURL: URL?
    func importFile(_ url: URL) {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            let ext = url.pathExtension.lowercased()
            if ext == "ipa" || ext == "zip" {
                let copy = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "." + ext)
                try FileManager.default.copyItem(at: url, to: copy)
                if let old = archiveURL { try? FileManager.default.removeItem(at: old) }
                archiveURL = copy
                ipaName = url.lastPathComponent
                inspect()
                discoverSource()
                Task { await discoverPublicSource() }
            } else {
                let data = try Data(contentsOf: url)
                guard data.count < 5_000_000, let text = String(data:data,encoding:.utf8) else {
                    findings = "Log must be UTF-8 and smaller than 5 MB.";return
                }
                logText = text
                logName = url.lastPathComponent
                inspect()
            }
        } catch { findings = "Import error: " + error.localizedDescription }
    }
    func removeIPA() {
        if let old = archiveURL { try? FileManager.default.removeItem(at: old) }
        archiveURL = nil
        ipaName = ""
        proposedFix = ""
        inspect()
    }
    func removeLog() {
        logText = ""
        logName = ""
        proposedFix = ""
        inspect()
    }
    func inspect() {
        var lines:[String] = []
        sourceAvailable = false
        if let archiveURL {
            do {
                let archive = try Archive(url:archiveURL,accessMode:.read)
                let entries = Array(archive)
                let manifests = entries.filter { $0.path.hasPrefix("Payload/") && $0.path.hasSuffix(".app/Info.plist") }
                let sources = entries.filter { $0.path.hasSuffix(".swift") || $0.path.hasSuffix(".m") || $0.path.hasSuffix(".mm") }
                sourceAvailable = !sources.isEmpty
                lines.append("IPA: " + ipaName + "; Entries: " + String(entries.count))
                lines.append("App manifests: " + String(manifests.count) + "; Source files: " + String(sources.count))
                if let entry = manifests.first {
                    var data = Data()
                    _ = try archive.extract(entry, consumer: { data.append($0) })
                    if let info = try PropertyListSerialization.propertyList(from:data,format:nil) as? [String:Any] {
                        lines.append("Bundle ID: " + String(describing:info["CFBundleIdentifier"] ?? "missing"))
                        lines.append("Version: " + String(describing:info["CFBundleShortVersionString"] ?? "missing"))
                        lines.append("Executable: " + String(describing:info["CFBundleExecutable"] ?? "missing"))
                    }
                }
            } catch { lines.append("IPA inspection failed: " + error.localizedDescription) }
        }
        let lower = logText.lowercased()
        if !logText.isEmpty {
            lines.append("Imported diagnostic log (" + String(logText.utf8.count) + " bytes).")
            for marker in ["exception type:", "termination reason:", "dyld:", "symbol not found", "fatal error:", "out of memory", "jetsam", "watchdog", "abort trap", "code signature"] {
                if lower.contains(marker) { lines.append("Detected: " + marker) }
            }
            let evidence = logText.components(separatedBy:.newlines).filter {
                let s = $0.lowercased()
                return s.contains("exception type") || s.contains("termination reason") || s.contains("dyld") || s.contains("fatal error") || s.contains("code signature")
            }
            lines.append(contentsOf:evidence.prefix(8).map { String($0.prefix(350)) })
        }
        if !issue.isEmpty { lines.append("Reported symptoms: " + issue) }
        lines.append(sourceAvailable ? "Source files appear in archive, but must be matched to an editable project before recompilation." : "Compiled IPA normally contains no recoverable original Swift/Objective-C source. Automatic source patching requires the source project.")
        findings = lines.joined(separator:"\n")
    }
    func discoverSource() {
        guard let archiveURL else { sourceDiscoveryReport = "Import an IPA or ZIP first."; return }
        sourceDiscoveryReport = SourceDiscovery.inspect(archiveURL)
    }
    func discoverPublicSource() async {
        guard let archiveURL else { repositoryDiscoveryReport = "Import an IPA first."; return }
        repositoryDiscoveryReport = "Searching public repositories…"
        repositoryDiscoveryReport = await SourceDiscovery.searchPublicRepositories(archiveURL)
    }
    func analyzeBinaryEvidence() {
        guard let archiveURL else { evidenceStatus = "Import an IPA first."; return }
        do {
            evidenceReport = try BinaryReconstruction.generateReport(ipa:archiveURL)
            evidenceStatus = "Extracted available metadata, resource inventory, and printable binary evidence. This is not original source code."
        } catch { evidenceStatus = "Binary analysis failed: " + error.localizedDescription }
    }
    func reconstructApp() {
        reconstructed = false
        let builder = WebAppBuilder()
        let requestedName = ipaName.replacingOccurrences(of: ".ipa", with: "", options: .caseInsensitive)
        let cleanName = requestedName.isEmpty ? "RecoveredApp" : String(requestedName.prefix(45))
        let escaped = issue.replacingOccurrences(of:"&",with:"&amp;").replacingOccurrences(of:"<",with:"&lt;").replacingOccurrences(of:">",with:"&gt;").replacingOccurrences(of:"\\\"",with:"&quot;")
        builder.appName = cleanName + " Rebuild"
        builder.bundleID = "com.localcoder.reconstructed." + UUID().uuidString.replacingOccurrences(of:"-",with:"").lowercased()
        builder.html = """
        <!doctype html><html><head><meta name="viewport" content="width=device-width, initial-scale=1">
        <style>body{font-family:-apple-system,system-ui;background:#111827;color:#f9fafb;padding:24px}
        .notice{background:#273449;padding:16px;border-radius:14px}button{padding:12px;border-radius:9px}</style></head>
        <body><h1>\(cleanName)</h1><div class="notice"><h2>Fresh replacement project</h2>
        <p>The original executable source was not available. This is a new functioning app shell, not a recovered copy of the original app.</p>
        <h3>Requested behavior / issue</h3><p>\(escaped)</p>
        <p>Unimplemented original features must be recreated from requirements or authorized source code.</p></div></body></html>
        """
        builder.exportIPA()
        guard let output = builder.output else { automaticStatus = "Replacement build failed: " + builder.status; return }
        repairedIPA = output
        reconstructed = true
        automaticStatus = "Created a new unsigned replacement app from the offline WebKit template. This is a fresh starter shell, not a repaired native executable. " + builder.status
    }
    func automaticRepair() {
        repairedIPA = nil
        reconstructed = false
        automaticStatus = "Inspecting imported archive and diagnostic evidence…"
        guard archiveURL != nil else {
            automaticStatus = "Import an IPA to attempt automatic repair."
            createRepairPlan()
            return
        }
        createRepairPlan()
        do {
            let (result, message) = try SafeIPARepair.repairMissingDisplayName(archiveURL!)
            repairedIPA = result
            automaticStatus = "Validated metadata repair completed. " + message
        } catch {
            let reason = error.localizedDescription
            reconstructApp()
            automaticStatus = "Original IPA could not be safely patched (" + reason + "). " + automaticStatus
        }
    }
    func repairSupportedIssue() {
        guard let archiveURL else { proposedFix = "Import an IPA first."; return }
        do {
            let (newIPA, report) = try SafeIPARepair.repairMissingDisplayName(archiveURL)
            repairedIPA = newIPA
            proposedFix = report
        } catch { proposedFix = "Automatic repair not applicable: " + error.localizedDescription + ". Native executable recompilation requires its source code and a validated compiler." }
    }
    func createRepairPlan() {
        inspect()
        let l = (logText + " " + issue).lowercased()
        if l.contains("dyld") || l.contains("symbol not found") {
            proposedFix = "Likely dynamic library or symbol-loading issue. Inspect embedded frameworks, architectures and load commands. A source/build configuration or linker repair may be necessary."
        } else if l.contains("jetsam") || l.contains("out of memory") || l.contains("memorystatus") {
            proposedFix = "Likely memory pressure. Profile allocation, reduce peak usage, and inspect device memory reports. Source changes and repeat testing are required."
        } else if l.contains("code signature") {
            proposedFix = "Code-signature validation issue. Repackaging invalidates signatures; a separately signed installation build is required. No automatic signing performed."
        } else if l.contains("watchdog") {
            proposedFix = "Potential main-thread stall or launch timeout. Examine the crashing thread and move blocking work off the main actor."
        } else {
            proposedFix = "Insufficient evidence for a specific patch. Compare the full crash log, executable UUID/dSYM, app version and source. Do not modify the executable based on a guess."
        }
        proposedFix += "\nOnly validated bundle-metadata repairs can currently generate replacement IPAs. Native executable recompilation requires source and a working compiler."
    }
}
struct RepairView: View {
    @State private var model = RepairWorkspace()
    @State private var picker = false
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment:.leading,spacing:12) {
                    Text("Crash & IPA Repair").font(.title2).bold()
                    Text("Import an IPA, crash log, or both. Describe the issue when no log is available.").font(.footnote).foregroundStyle(.secondary)
                    Menu {
                        Button("Add IPA or ZIP", systemImage:"archivebox") { picker = true }
                        Button("Add diagnostic log", systemImage:"doc.text") { picker = true }
                        Button("Add source or other file", systemImage:"folder") { picker = true }
                    } label: {
                        Label("Add attachment", systemImage:"plus.circle.fill")
                    }.buttonStyle(.borderedProminent)
                    if !model.ipaName.isEmpty || !model.logName.isEmpty {
                        ScrollView(.horizontal) {
                            HStack {
                                if !model.ipaName.isEmpty {
                                    HStack {
                                        Image(systemName:"archivebox")
                                        Text(model.ipaName).lineLimit(1)
                                        Button { model.removeIPA() } label: { Image(systemName:"xmark.circle.fill") }
                                    }.padding(8).background(.gray.opacity(0.2)).clipShape(Capsule())
                                }
                                if !model.logName.isEmpty {
                                    HStack {
                                        Image(systemName:"doc.text")
                                        Text(model.logName).lineLimit(1)
                                        Button { model.removeLog() } label: { Image(systemName:"xmark.circle.fill") }
                                    }.padding(8).background(.gray.opacity(0.2)).clipShape(Capsule())
                                }
                            }.font(.caption)
                        }
                    } else {
                        Text("No attachments selected").font(.caption).foregroundStyle(.secondary)
                    }
                    TextField("What happened?",text:$model.issue,axis:.vertical).lineLimit(2...5).textFieldStyle(.roundedBorder)
                    Button("Find source automatically") { model.discoverSource() }.buttonStyle(.bordered)
                    Text(model.sourceDiscoveryReport).font(.system(.caption,design:.monospaced)).textSelection(.enabled)
                    Button("Search public source repositories") { Task { await model.discoverPublicSource() } }.buttonStyle(.bordered)
                    Text(model.repositoryDiscoveryReport).font(.system(.caption,design:.monospaced)).textSelection(.enabled)
                    Button("Analyze and recommend fix") { model.createRepairPlan() }.buttonStyle(.bordered)
                    Button("Auto-diagnose, repair & export when possible") { model.automaticRepair() }.buttonStyle(.borderedProminent)
                    Text(model.automaticStatus).font(.caption).textSelection(.enabled)
                    Button("Analyze compiled binary evidence") { model.analyzeBinaryEvidence() }.buttonStyle(.bordered)
                    Text(model.evidenceStatus).font(.caption).textSelection(.enabled)
                    if let evidence = model.evidenceReport {
                        ShareLink(item:evidence) { Label("Export reconstruction evidence",systemImage:"square.and.arrow.up") }
                    }
                    Button("Create new app when source is unavailable") { model.reconstructApp() }.buttonStyle(.bordered)
                    if model.reconstructed { Text("Replacement shell only; original app functions are not automatically recovered.").font(.caption).foregroundStyle(.orange) }
                    Button("Repair missing app display name & rebuild unsigned IPA") { model.repairSupportedIssue() }.buttonStyle(.bordered)
                    if let repaired = model.repairedIPA {
                        ShareLink(item: repaired) { Label(model.reconstructed ? "Export replacement starter IPA" : "Export repaired unsigned IPA",systemImage:"square.and.arrow.up") }
                    }
                    Text("Findings").font(.headline)
                    Text(model.findings).font(.system(.caption,design:.monospaced)).textSelection(.enabled)
                    if !model.proposedFix.isEmpty {
                        Text("Repair recommendation").font(.headline)
                        Text(model.proposedFix).textSelection(.enabled)
                    }
                }.padding()
            }.scrollDismissesKeyboard(.interactively).navigationTitle("Repair")
            .sheet(isPresented:$picker) {
                UnrestrictedFilePicker(onPick:{ url in picker=false; model.importFile(url) },onFailure:{ msg in picker=false;model.findings=msg })
            }
        }
    }
}
