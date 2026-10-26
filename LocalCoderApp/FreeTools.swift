import SwiftUI
import UniformTypeIdentifiers
import ZIPFoundation

struct LocalTool: Identifiable {
    let id: String
    let name: String
    let description: String
    let symbol: String
}
enum FreeToolCatalog {
    static let all: [LocalTool] = [
        .init(id:"source", name:"Source Editor",description:"Import, edit and export UTF-8 project files offline.",symbol:"chevron.left.forwardslash.chevron.right"),
        .init(id:"ipa", name:"IPA Inspector",description:"Inspect IPA manifests, frameworks and signature resources.",symbol:"archivebox"),
        .init(id:"pack", name:"IPA Packager",description:"Package existing compiled .app bundles without signing.",symbol:"shippingbox"),
        .init(id:"chat", name:"Local AI Chat",description:"Ask Apple's on-device model for code and diagnostic suggestions.",symbol:"brain")
    ]
}
@MainActor @Observable final class SourceWorkspace {
    var text = ""
    var filename = "NewFile.swift"
    var status = "Create a source file or import one from Files."
    var exported: URL?
    func importFile(_ url: URL) {
        let secured = url.startAccessingSecurityScopedResource()
        defer { if secured { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            guard data.count < 3_000_000, let value = String(data: data, encoding: .utf8) else {
                status = "Only UTF-8 source files smaller than 3 MB are supported."
                return
            }
            text = value
            filename = url.lastPathComponent
            status = "Imported \(filename) locally."
        } catch { status = "Import failed: \(error.localizedDescription)" }
    }
    func save() {
        do {
            let safe = URL(fileURLWithPath: filename).lastPathComponent
            guard !safe.isEmpty, safe != "." else { status = "Enter a valid filename."; return }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "-" + safe)
            try Data(text.utf8).write(to: url, options: .atomic)
            exported = url
            status = "Ready to export \(safe). Native compilation is not included."
        } catch { status = "Export failed: \(error.localizedDescription)" }
    }
}
struct SourceEditorView: View {
    @State private var workspace = SourceWorkspace()
    @State private var importing = false
    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Button("Import") { importing = true }.buttonStyle(.bordered)
                    Button("Export") { workspace.save() }.buttonStyle(.borderedProminent)
                    if let url = workspace.exported {
                        ShareLink(item: url) { Label("Files", systemImage:"square.and.arrow.up") }
                    }
                }
                TextField("Filename", text: $workspace.filename).textInputAutocapitalization(.never)
                    .textFieldStyle(.roundedBorder)
                TextEditor(text: $workspace.text)
                    .font(.system(size: 13, design: .monospaced))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(.gray.opacity(0.25)))
                Text(workspace.status).font(.caption).foregroundStyle(.secondary)
            }
            .padding()
            .navigationTitle("Source Editor")
            .fileImporter(isPresented: $importing, allowedContentTypes:[.plainText, .sourceCode, .data], allowsMultipleSelection:false) { result in
                switch result {
                case .success(let urls): if let url = urls.first { workspace.importFile(url) }
                case .failure(let error): workspace.status = error.localizedDescription
                }
            }
        }
    }
}
struct FreeToolsView: View {
    var body: some View {
        NavigationStack {
            List(FreeToolCatalog.all) { tool in
                HStack(alignment:.top, spacing:14) {
                    Image(systemName:tool.symbol).frame(width:24)
                    VStack(alignment:.leading,spacing:4) {
                        Text(tool.name).font(.headline)
                        Text(tool.description).font(.caption).foregroundStyle(.secondary)
                    }
                }.padding(.vertical,5)
            }
            .navigationTitle("Free Tools")
            .safeAreaInset(edge:.bottom) {
                Text("Built-in, offline tools. This release does not load arbitrary third-party plugin code or compile new native iOS executables.")
                    .font(.caption).foregroundStyle(.secondary).padding()
            }
        }
    }
}
