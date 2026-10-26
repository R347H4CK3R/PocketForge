import SwiftUI
import UniformTypeIdentifiers
import ZIPFoundation

@MainActor @Observable final class BundlePackager {
    var status = "Select a .app folder from Files to package an existing compiled app offline."
    var output: URL?
    func package(_ folder: URL) {
        let secured = folder.startAccessingSecurityScopedResource()
        defer { if secured { folder.stopAccessingSecurityScopedResource() } }
        do {
            let fm = FileManager.default
            guard folder.pathExtension.lowercased() == "app" else {
                status = "Select an existing .app bundle, not a source project. Native compilation is not available in this build."
                return
            }
            let plistURL = folder.appendingPathComponent("Info.plist")
            let plist = try Data(contentsOf: plistURL)
            guard let dictionary = try PropertyListSerialization.propertyList(from: plist, format: nil) as? [String: Any],
                  let executable = dictionary["CFBundleExecutable"] as? String,
                  !executable.isEmpty,
                  let identifier = dictionary["CFBundleIdentifier"] as? String,
                  !identifier.isEmpty else {
                status = "Invalid app bundle: required Info.plist fields are missing."
                return
            }
            guard fm.fileExists(atPath: folder.appendingPathComponent(executable).path) else {
                status = "Missing executable: \(executable). Cannot package a usable app without a compiled binary."
                return
            }
            let root = fm.temporaryDirectory.appendingPathComponent("LocalCoder-" + UUID().uuidString, isDirectory: true)
            defer { try? fm.removeItem(at: root) }
            let payload = root.appendingPathComponent("Payload", isDirectory: true)
            try fm.createDirectory(at: payload, withIntermediateDirectories: true)
            let destination = payload.appendingPathComponent(folder.lastPathComponent, isDirectory: true)
            try fm.copyItem(at: folder, to: destination)
            let result = fm.temporaryDirectory.appendingPathComponent("LocalCoder-" + UUID().uuidString + ".ipa")
            try fm.zipItem(at: payload, to: result, shouldKeepParent: true)
            output = result
            status = "Unsigned IPA packaged locally from \(identifier). This repackages an existing executable; it does not compile source or produce a new signature."
        } catch {
            status = "Packaging failed: \(error.localizedDescription)"
        }
    }
}
struct BuildLocalView: View {
    @State private var packager = BundlePackager()
    @State private var picking = false
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Offline IPA Packager").font(.title2).bold()
                    Text("Import an existing compiled .app folder, validate its manifest and executable, and export an unsigned IPA. No laptop, account, signing service, or network is required.")
                    Button("Choose .app Folder") { picking = true }.buttonStyle(.borderedProminent)
                    Text(packager.status).font(.footnote).textSelection(.enabled)
                    if let url = packager.output {
                        ShareLink(item: url) { Label("Export unsigned IPA", systemImage: "square.and.arrow.up") }
                    }
                    Divider()
                    Text("Compiler status").font(.headline)
                    Text("Native Swift/Objective-C compilation is not bundled. Importing only source code cannot create an executable IPA. Repackaged binaries remain unsigned or signature-invalid.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }.padding()
            }
            .navigationTitle("Build Locally")
            .fileImporter(isPresented: $picking, allowedContentTypes: [.folder], allowsMultipleSelection: false) { result in
                switch result {
                case .success(let urls):
                    if let url = urls.first { packager.package(url) }
                case .failure(let error):
                    packager.status = error.localizedDescription
                }
            }
        }
    }
}
