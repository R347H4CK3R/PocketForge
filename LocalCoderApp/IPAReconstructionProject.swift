import Foundation
import ZIPFoundation

/// Builds an editable reconstruction starting point from an IPA's available evidence.
/// Does not decompile or reproduce the original program's logic.
enum IPAReconstructionProject {
    static func export(from ipa: URL) throws -> (URL, String) {
        let fm = FileManager.default
        let archive = try Archive(url: ipa, accessMode: .read)
        let files = Array(archive)
        guard files.count < 40000 else {
            throw NSError(domain: "PocketForge", code: 1, userInfo: [NSLocalizedDescriptionKey: "Archive has too many entries for safe inspection."])
        }
        let manifests = files.filter { $0.path.hasPrefix("Payload/") && $0.path.hasSuffix(".app/Info.plist") }
        guard manifests.count == 1, let manifest = manifests.first else {
            throw NSError(domain: "PocketForge", code: 2, userInfo: [NSLocalizedDescriptionKey: "Expected exactly one app manifest inside Payload."])
        }
        var data = Data()
        _ = try archive.extract(manifest, consumer: { data.append($0) })
        guard let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw NSError(domain: "PocketForge", code: 3, userInfo: [NSLocalizedDescriptionKey: "Unable to parse app metadata."])
        }
        let originalName = (plist["CFBundleDisplayName"] as? String) ??
            (plist["CFBundleName"] as? String) ?? "Imported Application"
        let bundleID = (plist["CFBundleIdentifier"] as? String) ?? "unknown"
        let executable = (plist["CFBundleExecutable"] as? String) ?? "unknown"
        let source = files.filter {
            let p = $0.path.lowercased()
            return [".swift", ".m", ".mm", ".c", ".cpp"].contains(where: p.hasSuffix)
        }
        let evidence = files.filter {
            let p = $0.path.lowercased()
            return [".png", ".jpg", ".jpeg", ".car", ".nib", ".storyboardc", ".strings", ".json", ".plist", ".metallib", ".caf", ".wav", ".mp3", ".map"].contains(where: p.hasSuffix)
        }
        var architecture = "Executable not inspected"
        let binaryPath = String(manifest.path.dropLast("Info.plist".count)) + executable
        if let binary = files.first(where: { $0.path == binaryPath }) {
            var prefix = Data()
            _ = try archive.extract(binary, consumer: { chunk in
                if prefix.count < 4096 { prefix.append(chunk.prefix(4096 - prefix.count)) }
            })
            architecture = BinaryReconstruction.architectureDescription(prefix)
        }
        let root = fm.temporaryDirectory.appendingPathComponent("PocketForge-Reconstruction-" + UUID().uuidString, isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        let project = root.appendingPathComponent("ReconstructedApp", isDirectory: true)
        try fm.createDirectory(at: project, withIntermediateDirectories: true)
        let safeTitle = originalName.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: " ")
        let swift = """
        import SwiftUI

        // POCKETFORGE GENERATED RECONSTRUCTION SCAFFOLD
        // This is NEW source based on metadata; the original source was NOT decompiled.
        // Original bundle identifier: \(bundleID)
        // Original executable: \(executable)
        @main struct ReconstructedApp: App {
            var body: some Scene {
                WindowGroup { ReconstructionHome() }
            }
        }

        struct ReconstructionHome: View {
            var body: some View {
                NavigationStack {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("\(safeTitle)").font(.largeTitle).bold()
                        Text("Reconstruction starter project").font(.headline)
                        Text("This app shell does not contain the original app's gameplay or native functionality.")
                        Text("Add verified screens, logic, and assets to recreate required behavior.")
                        Spacer()
                    }
                    .padding()
                    .navigationTitle("Reconstruction")
                }
            }
        }
        """
        try swift.write(to: project.appendingPathComponent("ReconstructedApp.swift"), atomically: true, encoding: .utf8)
        let resources = evidence.prefix(5000).map(\.path).joined(separator: "\n")
        try resources.write(to: project.appendingPathComponent("RESOURCE_INVENTORY.txt"), atomically: true, encoding: .utf8)
        let report = """
        PocketForge reconstruction evidence
        Original app: \(originalName)
        Bundle identifier: \(bundleID)
        Executable: \(executable)
        Architecture: \(architecture)
        Source files packaged: \(source.count)
        Resource candidates: \(evidence.count)

        Output: editable SwiftUI starter application and resource inventory.
        This does not recover the original algorithms, game logic, engine or full UI.
        Before native execution, rebuild with a verified ARM64 compiler, resolve dependencies,
        and test on the target device. Do not assume rights to redistribute bundled assets.
        """
        try report.write(to: project.appendingPathComponent("RECONSTRUCTION_REPORT.txt"), atomically: true, encoding: .utf8)
        let export = fm.temporaryDirectory.appendingPathComponent("PocketForge-ReconstructedSource-" + UUID().uuidString + ".zip")
        try fm.zipItem(at: project, to: export)
        guard let verify = try? Archive(url: export, accessMode: .read),
              verify.contains(where: { $0.path.hasSuffix("ReconstructedApp.swift") }) else {
            try? fm.removeItem(at: export)
            throw NSError(domain: "PocketForge", code: 4, userInfo: [NSLocalizedDescriptionKey: "Could not verify exported source ZIP."])
        }
        return (export, report)
    }
}
