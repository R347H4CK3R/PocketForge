import Foundation
import ZIPFoundation

/// Offline, source-free repair limited to verifiable bundle metadata.
/// Does not attempt to rewrite an opaque Mach-O executable.
enum SafeIPARepair {
    static func repairMissingDisplayName(_ ipa: URL) throws -> (URL, String) {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("repair-" + UUID().uuidString, isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let archive = try Archive(url: ipa, accessMode: .read)
        let all = Array(archive)
        guard all.count < 30000 else { throw NSError(domain:"LocalCoderRepair",code:1,userInfo:[NSLocalizedDescriptionKey:"Too many archive entries"]) }
        guard !all.contains(where: { $0.path.hasPrefix("/") || $0.path.split(separator:"/").contains("..") || $0.type == .symlink }) else {
            throw NSError(domain:"LocalCoderRepair",code:2,userInfo:[NSLocalizedDescriptionKey:"Unsafe archive path or symbolic link"])
        }
        let names = all.filter { $0.path.hasPrefix("Payload/") && $0.path.hasSuffix(".app/Info.plist") }
        guard names.count == 1, let entry = names.first else {
            throw NSError(domain:"LocalCoderRepair",code:3,userInfo:[NSLocalizedDescriptionKey:"Expected exactly one app Info.plist"])
        }
        var plistData = Data()
        _ = try archive.extract(entry, consumer: { plistData.append($0) })
        guard let raw = try PropertyListSerialization.propertyList(from:plistData,format:nil) as? [String:Any],
              let executable = raw["CFBundleExecutable"] as? String, !executable.isEmpty,
              let identifier = raw["CFBundleIdentifier"] as? String, !identifier.isEmpty else {
            throw NSError(domain:"LocalCoderRepair",code:4,userInfo:[NSLocalizedDescriptionKey:"Invalid app metadata"])
        }
        guard raw["CFBundleDisplayName"] == nil else {
            throw NSError(domain:"LocalCoderRepair",code:5,userInfo:[NSLocalizedDescriptionKey:"Display name already exists; no justified automatic change"])
        }
        let appDirectory = String(entry.path.dropLast("Info.plist".count))
        guard all.contains(where:{ $0.path == appDirectory + executable }) else {
            throw NSError(domain:"LocalCoderRepair",code:6,userInfo:[NSLocalizedDescriptionKey:"App executable not found"])
        }
        try fm.unzipItem(at:ipa,to:root)
        var corrected = raw
        corrected["CFBundleDisplayName"] = raw["CFBundleName"] as? String ?? "Repaired App"
        let newPlist = try PropertyListSerialization.data(fromPropertyList:corrected,format:.xml,options:0)
        try newPlist.write(to:root.appendingPathComponent(entry.path),options:.atomic)
        // A changed bundle cannot retain its original, now-invalid signature resources.
        let codesign = root.appendingPathComponent(appDirectory).appendingPathComponent("_CodeSignature")
        if fm.fileExists(atPath:codesign.path) { try fm.removeItem(at:codesign) }
        let output = fm.temporaryDirectory.appendingPathComponent("LocalCoder-Repaired-"+UUID().uuidString+".ipa")
        try fm.zipItem(at:root.appendingPathComponent("Payload"),to:output,shouldKeepParent:true)
        let verify = try Archive(url:output,accessMode:.read)
        guard verify.contains(where:{$0.path == entry.path}) else {
            try? fm.removeItem(at:output)
            throw NSError(domain:"LocalCoderRepair",code:7,userInfo:[NSLocalizedDescriptionKey:"Repacked IPA integrity check failed"])
        }
        return (output,"Repaired missing display name in Info.plist. This is an unsigned resource-level repair, not native recompilation. No executable instructions were changed.")
    }
}
