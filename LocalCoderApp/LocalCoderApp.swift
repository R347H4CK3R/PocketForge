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
                    ScrollView { LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(brain.lines.indices, id: \.self) { index in Text(brain.lines[index]).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                    }.padding() }.scrollDismissesKeyboard(.interactively)
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
            }.tabItem { Label("AI Chat", systemImage: "bubble.left.and.bubble.right") }
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Diagnose an IPA offline").font(.title2).bold()
                        Button("Import IPA or ZIP") { importFile = true }.buttonStyle(.borderedProminent)
                        Text(inspector.report).font(.system(.footnote, design: .monospaced)).textSelection(.enabled)
                        ShareLink(item: inspector.report) { Label("Share diagnosis", systemImage: "square.and.arrow.up") }
                    }.padding()
                }.navigationTitle("IPA Inspector")
                .sheet(isPresented: $importFile) {
                    UnrestrictedFilePicker(onPick: { url in
                        importFile = false
                        inspector.inspect(url)
                    }, onFailure: { message in
                        importFile = false
                        inspector.report = message
                    })
                }
            }.tabItem { Label("Inspect", systemImage: "archivebox") }
            RepairView().tabItem { Label("Repair", systemImage: "wrench.and.screwdriver") }
            SourceEditorView().tabItem { Label("Source", systemImage: "chevron.left.forwardslash.chevron.right") }
            NativeCompilerView().tabItem { Label("Native", systemImage: "curlybraces") }
            SDKManagementView().tabItem { Label("SDK", systemImage: "externaldrive") }
            WebAppBuilderView().tabItem { Label("Create App", systemImage: "hammer") }
            BuildLocalView().tabItem { Label("Pack IPA", systemImage: "shippingbox") }
            FreeToolsView().tabItem { Label("Tools", systemImage: "square.grid.2x2") }
        }
    }
}
struct EmbeddedBrowser: UIViewRepresentable {
    let url: URL
    func makeUIView(context: Context) -> WKWebView { let view = WKWebView(); view.load(URLRequest(url: url)); return view }
    func updateUIView(_ webView: WKWebView, context: Context) {}
}
