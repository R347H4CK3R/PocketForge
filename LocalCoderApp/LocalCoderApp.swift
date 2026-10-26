import SwiftUI
import WebKit
import FoundationModels
import ZIPFoundation
import UniformTypeIdentifiers
import UIKit

@main struct LocalCoderApp: App {
    var body: some Scene { WindowGroup { MainScreen().preferredColorScheme(.dark) } }
}
@MainActor @Observable final class Brain {
    var prompt = ""
    var lines: [String] = []
    var error = ""
    var busy = false
    var attachments = AttachmentStore()
    var nativeProject = NativeProjectWorkspace()
    var nativeDraftReady = false
    var webDraft = ""
    var webPreviewReady = false
    var taskReport = ""
    var agentOutput: URL?
    private var session: LanguageModelSession?
    func generateWebPreview() async {
        let request = prompt.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !request.isEmpty && !busy else { error = "Describe an app to run."; return }
        guard SystemLanguageModel.default.isAvailable else { error = "On-device AI unavailable."; return }
        busy = true
        defer { busy = false }
        do {
            let generator = LanguageModelSession(instructions: "Generate a complete, self-contained HTML5 application with CSS and JavaScript. Output only HTML source beginning with <!doctype html>. No remote dependencies. No markdown formatting.")
            var result = try await generator.respond(to: request).content
            if result.hasPrefix("```") {
                let parts = result.components(separatedBy:.newlines)
                if parts.count >= 3 { result = parts.dropFirst().dropLast().joined(separator:"\n") }
            }
            guard result.lowercased().contains("<html"), result.lowercased().contains("</html>") else {
                error = "Model did not produce complete HTML. Try again."; return
            }
            webDraft = result
            webPreviewReady = true
            lines.append("AI: Generated a temporary HTML app ready for in-app Run. Session storage is not persistent.")
            error = ""
        } catch { self.error = "App generation failed: " + error.localizedDescription }
    }
    func generateNativeProject() async {
        let request = prompt.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !request.isEmpty, !busy else { error = "Describe the native iOS app first."; return }
        guard SystemLanguageModel.default.isAvailable else { error = "On-device language model unavailable."; return }
        busy = true
        defer { busy = false }
        do {
            let session = LanguageModelSession(instructions: """
            You write SwiftUI iOS application source code for a single Swift file.
            Output only a complete Swift code file, with import SwiftUI and exactly one @main App entrypoint.
            Do not write markdown fences or explanations. Avoid unimplemented placeholders.
            Do not claim compilation, signing, installation, or device testing.
            """)
            let result = try await session.respond(to:request)
            var code = result.content.trimmingCharacters(in:.whitespacesAndNewlines)
            if code.hasPrefix("```") {
                let lines = code.components(separatedBy:.newlines)
                if lines.count >= 3 { code = lines.dropFirst().dropLast().joined(separator:"\n") }
            }
            guard code.contains("import SwiftUI"), code.contains("@main"), code.utf8.count <= 400_000 else {
                error = "Model output was not a valid single-file SwiftUI app draft. Regenerate with more detail."
                return
            }
            nativeProject.language = .swift
            nativeProject.projectName = "AIApp"
            nativeProject.source = code
            nativeProject.output = nil
            nativeDraftReady = true
            lines.append("AI: Generated editable native SwiftUI app source. Export project ZIP to build using a verified toolchain. No executable has been compiled.")
            error = ""
        } catch { self.error = "Native project generation failed: " + error.localizedDescription }
    }
    func routeRequest() {
        Task { await runAgent() }
    }
    func runAgent() async {
        let request = prompt.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !request.isEmpty && !busy else { error = "Describe a development task first."; return }
        let files = attachments.items.map(\.name)
        let fallback = ForgeTaskRouter.classify(request, attachments: files)
        taskReport = "Agent: assessing request and available tools…"
        var selected = fallback.kind
        if SystemLanguageModel.default.isAvailable {
            do {
                let planner = LanguageModelSession(instructions: """
                You are a development tool planner. Choose exactly one tool for this request:
                WEB = create runnable HTML/CSS/JavaScript application;
                NATIVE = generate editable SwiftUI source project;
                INSPECT = inspect an imported iOS app or diagnose a crash;
                ADVISE = research or explain a technical issue.
                Reply with only WEB, NATIVE, INSPECT, or ADVISE. Never claim an unavailable capability.
                """)
                let decision = try await planner.respond(to:request+"\nAttached files: "+files.joined(separator:", "))
                switch decision.content.trimmingCharacters(in:.whitespacesAndNewlines).uppercased() {
                case "WEB": selected = .rebuildWeb
                case "NATIVE": selected = .generateNative
                case "INSPECT": selected = .inspectIPA
                case "ADVISE": selected = .general
                default: break
                }
            } catch { taskReport = "Model planning unavailable: "+error.localizedDescription+"\nUsing deterministic routing." }
        }
        switch selected {
        case .rebuildWeb:
            taskReport = "Selected: web app generation → validation → unsigned IPA packaging."
            await generateWebPreview()
            if webPreviewReady {
                let builder = WebAppBuilder()
                builder.appName = "ForgeGenerated"
                builder.bundleID = "dev.pocketforge.generated."+UUID().uuidString.replacingOccurrences(of:"-",with:"").lowercased()
                builder.html = webDraft
                builder.exportIPA()
                if let output = builder.output {
                    agentOutput = output
                    taskReport += "\nGenerated HTML; created unsigned IPA. Open Run temporary app to test the web UI. This is not a native gameplay port."
                } else {
                    taskReport += "\nPackaging failed: "+builder.status
                }
            } else { taskReport += "\nGeneration not completed. "+error }
        case .generateNative:
            taskReport = "Selected: native SwiftUI source generation → source validation → project ZIP."
            await generateNativeProject()
            if nativeDraftReady {
                nativeProject.exportProject()
                agentOutput = nativeProject.output
                taskReport += "\nSwift source project exported. Native compiler/linker execution on iPhone is not yet verified."
            } else { taskReport += "\nSource generation not completed. "+error }
        case .inspectIPA, .diagnoseLog, .unsupportedNative:
            taskReport = "Selected: native app analysis. Import the IPA and diagnostic log in Repair to inspect real binaries. Arbitrary native binary conversion cannot run via this chat alone."
        case .general:
            taskReport = "Selected: technical reasoning. Responding with analysis; no external code execution is available in this mode."
            await send()
        }
    }
    func send() async {
        let value = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (!value.isEmpty || !attachments.items.isEmpty) && !busy else { return }
        guard SystemLanguageModel.default.isAvailable else { error = "Apple on-device model unavailable. Enable Apple Intelligence."; return }
        let attachmentNames = attachments.items.map(\.name)
        let attachmentContext = attachments.consumeContext()
        prompt = ""
        lines.append("You: " + value + (attachmentNames.isEmpty ? "" : "\nAttachments: " + attachmentNames.joined(separator: ", ")))
        busy = true
        defer { busy = false }
        do {
            if session == nil {
                session = LanguageModelSession(instructions: "You are an iOS programming assistant. Help diagnose Swift, Xcode, app and IPA problems. You cannot compile native Swift iOS applications directly on a normal iPhone. Archive inspection is local, but source-code changes need an actual builder. Never claim you ran tests or signed code.")
            }
            let answer = try await session!.respond(to: value + (attachmentContext.isEmpty ? "" : "\n\nAttached file context:\n" + String(attachmentContext.prefix(35000))))
            lines.append("AI: " + answer.content)
            error = ""
        } catch { self.error = error.localizedDescription }
    }
}
@MainActor @Observable final class ArchiveInspector {
    var report = "Choose an IPA from Files to inspect its structure locally."
    var filename = ""
    func inspect(_ url: URL) {
        guard ["ipa", "zip"].contains(url.pathExtension.lowercased()) else { report = "Select an IPA or ZIP file."; return }
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".ipa")
            try FileManager.default.copyItem(at: url, to: destination)
            defer { try? FileManager.default.removeItem(at: destination) }
            let archive = try Archive(url: destination, accessMode: .read)
            let entries = Array(archive)
            let apps = entries.filter { $0.path.hasPrefix("Payload/") && $0.path.hasSuffix(".app/Info.plist") }
            let binaries = entries.filter { $0.path.hasSuffix("/_CodeSignature/CodeResources") }
            let frameworks = entries.filter { $0.path.contains(".app/Frameworks/") && $0.path.hasSuffix(".framework/") }
            var lines = ["Archive: \(url.lastPathComponent)", "Entries: \(entries.count)", "App manifests: \(apps.count)", "Code signature resources: \(binaries.count)", "Embedded frameworks: \(frameworks.count)"]
            if let entry = apps.first {
                var data = Data()
                _ = try archive.extract(entry, consumer: { data.append($0) })
                if let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
                    for key in ["CFBundleIdentifier","CFBundleDisplayName","CFBundleExecutable","CFBundleShortVersionString","MinimumOSVersion"] {
                        lines.append("\(key): \(plist[key] ?? "missing")")
                    }
                }
            } else { lines.append("WARNING: No Payload/*.app/Info.plist found.") }
            if binaries.isEmpty { lines.append("Unsigned or signature files absent; installation requires signing.") }
            lines.append("Inspecting does not rebuild a native binary. Editing compiled executable code requires source/toolchain and produces a signature-invalidating change.")
            filename = url.lastPathComponent
            report = lines.joined(separator: "\n")
        } catch { report = "Inspection failed: \(error.localizedDescription)" }
    }
}
struct MainScreen: View {
    @State private var brain = Brain()
    @State private var inspector = ArchiveInspector()
    @State private var importFile = false
    @State private var importChatAttachment = false
    @State private var showingChatPreview = false
    var body: some View {
        TabView {
            NavigationStack {
                VStack {
                    VStack(alignment:.leading,spacing:5) {
                        Text("What would you like to make?").font(.headline)
                        Text("Describe an app, paste an error, or attach a file. Tap the hammer for automatic app creation.").font(.caption).foregroundStyle(.secondary)
                    }.frame(maxWidth:.infinity,alignment:.leading).padding(.horizontal)
                    ScrollView { LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(brain.lines.indices, id: \.self) { index in Text(brain.lines[index]).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                    }.padding() }.scrollDismissesKeyboard(.interactively)
                    if !brain.taskReport.isEmpty {
                        Text(brain.taskReport).font(.system(.caption,design:.monospaced)).textSelection(.enabled).padding(.horizontal)
                    }
                    if let product = brain.agentOutput {
                        ShareLink(item:product) { Label("Export agent result",systemImage:"square.and.arrow.up") }.padding(.horizontal)
                    }
                    if brain.webPreviewReady {
                        HStack {
                            Button("Run temporary app") { showingChatPreview = true }.buttonStyle(.borderedProminent)
                            Button("Clear preview") { brain.webDraft = ""; brain.webPreviewReady = false }
                        }.padding(.horizontal)
                    }
                    if brain.nativeDraftReady {
                        VStack(alignment:.leading,spacing:8) {
                            Text("Native SwiftUI project generated").font(.headline)
                            Text("Source generated locally. A native compiler and SDK are required for an executable IPA.").font(.caption)
                            Button("Export native project ZIP") { brain.nativeProject.exportProject() }.buttonStyle(.bordered)
                            if let output = brain.nativeProject.output {
                                ShareLink(item:output) { Label("Save source project",systemImage:"square.and.arrow.up") }
                            }
                            Text(brain.nativeProject.status).font(.caption).textSelection(.enabled)
                            Text(brain.nativeProject.compilerReport).font(.caption).foregroundStyle(.secondary)
                        }.padding(.horizontal)
                    }
                    if !brain.error.isEmpty { Text(brain.error).foregroundStyle(.orange).font(.caption) }
                    if brain.busy { ProgressView() }
                    if !brain.attachments.items.isEmpty {
                        ScrollView(.horizontal) {
                            HStack {
                                ForEach(brain.attachments.items) { item in
                                    HStack(spacing: 5) {
                                        Image(systemName: "paperclip")
                                        Text(item.name).lineLimit(1)
                                        Button { brain.attachments.remove(item.id) } label: { Image(systemName: "xmark.circle.fill") }
                                    }.font(.caption).padding(8).background(.gray.opacity(0.2)).clipShape(Capsule())
                                }
                            }
                        }.padding(.horizontal)
                    }
                    if !brain.attachments.error.isEmpty { Text(brain.attachments.error).font(.caption).foregroundStyle(.orange) }
                    HStack {
                        Menu {
                            Button("Choose from Files", systemImage: "folder") { importChatAttachment = true }
                        } label: { Image(systemName:"plus.circle.fill").font(.title2).accessibilityLabel("Add attachment") }
                        TextField("Describe an app or paste an error", text: $brain.prompt, axis: .vertical)
                        Button("Send") { Task { await brain.send() } }.disabled(brain.busy)
                        Menu {
                            Button("Auto plan & execute",systemImage:"wand.and.stars") { brain.routeRequest() }
                            Button("Generate runnable web app",systemImage:"play.rectangle") { Task { await brain.generateWebPreview() } }
                            Button("Generate native SwiftUI source",systemImage:"curlybraces") { Task { await brain.generateNativeProject() } }
                            Button("Check native compiler",systemImage:"checkmark.shield") { brain.nativeProject.checkNativeCompiler() }
                        } label: { Image(systemName:"hammer.circle").font(.title2).accessibilityLabel("App build tools") }
                    }.padding()
                    .sheet(isPresented:$showingChatPreview) { EphemeralAppPreview(html:brain.webDraft) }
                    .sheet(isPresented: $importChatAttachment) {
                        UnrestrictedFilePicker(onPick: { url in
                            importChatAttachment = false
                            brain.attachments.add(url)
                        }, onFailure: { message in
                            importChatAttachment = false
                            brain.attachments.error = message
                        })
                    }
                }.navigationTitle("PocketForge AI")
            }.tabItem { Label("Create", systemImage: "wand.and.stars") }
            RepairView().tabItem { Label("Repair", systemImage: "wrench.and.screwdriver") }
            WebAppBuilderView().tabItem { Label("Run & Build", systemImage: "play.rectangle") }
            NavigationStack {
                List {
                    Section("How it works") {
                        Text("Create an app with AI, repair an imported IPA, or edit and run a web app. Use the tools below for advanced tasks.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    Section("Advanced tools") {
                        NavigationLink { NativeCompilerView() } label: { Label("Native source",systemImage:"curlybraces") }
                        NavigationLink { SDKManagementView() } label: { Label("Compiler setup",systemImage:"externaldrive") }
                        NavigationLink { SourceEditorView() } label: { Label("Source editor",systemImage:"chevron.left.forwardslash.chevron.right") }
                        NavigationLink { BuildLocalView() } label: { Label("Package IPA",systemImage:"shippingbox") }
                        NavigationLink { FreeToolsView() } label: { Label("Developer tools",systemImage:"square.grid.2x2") }
                    }
                    Section("Inspect IPA") {
                        Button("Import IPA or ZIP") { importFile = true }
                        Text(inspector.report).font(.caption).textSelection(.enabled)
                        ShareLink(item:inspector.report) { Label("Share inspection report",systemImage:"square.and.arrow.up") }
                    }
                }.navigationTitle("More")
                .sheet(isPresented:$importFile) {
                    UnrestrictedFilePicker(onPick:{url in importFile=false;inspector.inspect(url)},onFailure:{message in importFile=false;inspector.report=message})
                }
            }.tabItem { Label("More",systemImage:"ellipsis.circle") }
        }
    }
}
struct EmbeddedBrowser: UIViewRepresentable {
    let url: URL
    func makeUIView(context: Context) -> WKWebView { let view = WKWebView(); view.load(URLRequest(url: url)); return view }
    func updateUIView(_ webView: WKWebView, context: Context) {}
}
