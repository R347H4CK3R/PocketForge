import Foundation
import UniformTypeIdentifiers
import SwiftUI

@MainActor @Observable final class SDKWorkspace {
    var status = "Import an uncompressed iPhoneOS.sdk folder. An SDK is required before native code compilation."
    var sdkURL: URL?
    func importSDK(_ input: URL) {
        let access = input.startAccessingSecurityScopedResource()
        defer { if access { input.stopAccessingSecurityScopedResource() } }
        do {
            let fm = FileManager.default
            guard fm.fileExists(atPath: input.appendingPathComponent("SDKSettings.plist").path),
                  fm.fileExists(atPath: input.appendingPathComponent("usr/include").path) else {
                status = "Rejected: this folder lacks SDKSettings.plist or usr/include."
                return
            }
            let root = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            let target = root.appendingPathComponent("iPhoneOS.sdk",isDirectory:true)
            let staging = root.appendingPathComponent("SDK-staging-"+UUID().uuidString,isDirectory:true)
            try fm.copyItem(at:input,to:staging)
            guard fm.fileExists(atPath:staging.appendingPathComponent("SDKSettings.plist").path) else {
                try? fm.removeItem(at:staging)
                status = "SDK copy could not be verified."
                return
            }
            if fm.fileExists(atPath:target.path) { try fm.removeItem(at:target) }
            try fm.moveItem(at:staging,to:target)
            sdkURL = target
            status = "Imported SDK locally. \(NyxianCompilerProbe.inspect(sdkURL:target))"
        } catch { status = "SDK import failed: \(error.localizedDescription)" }
    }
    func recheck() {
        let root = FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask).first!
        let target = root.appendingPathComponent("iPhoneOS.sdk")
        status = NyxianCompilerProbe.inspect(sdkURL: FileManager.default.fileExists(atPath: target.path) ? target : nil)
    }
}
struct SDKManagementView: View {
    @State private var workspace = SDKWorkspace()
    @State private var choosing = false
    var body: some View {
        NavigationStack {
            Form {
                Section("Native SDK") {
                    Button("Import iPhoneOS.sdk folder") { choosing = true }
                    Button("Check compiler and SDK") { workspace.recheck() }
                    Text(workspace.status).font(.footnote).textSelection(.enabled)
                }
                Section("Native build tests") {
                    Text("Swift and Objective-C compilation/linking are unavailable until the compiler is initialized and its build jobs are implemented and tested. No successful native build is claimed.")
                        .font(.footnote)
                }
            }
            .navigationTitle("Compiler Setup")
            .fileImporter(isPresented:$choosing,allowedContentTypes:[.folder],allowsMultipleSelection:false) { result in
                switch result {
                case .success(let files): if let first=files.first { workspace.importSDK(first) }
                case .failure(let error): workspace.status=error.localizedDescription
                }
            }
        }
    }
}
