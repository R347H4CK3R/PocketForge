import Foundation
import ZIPFoundation

/// Evidence-based binary inventory. Never represents recovered metadata as original source.
enum BinaryReconstruction {
    private static func uint32(_ bytes: [UInt8], _ offset: Int, big: Bool) -> UInt32 {
        guard offset >= 0, offset + 4 <= bytes.count else { return 0 }
        let chunk = Array(bytes[offset..<(offset+4)])
        return big ? chunk.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) } :
            chunk.reversed().reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }
    static func architectureDescription(_ bytes: Data) -> String {
        let b = Array(bytes.prefix(4096))
        guard b.count >= 12 else { return "Truncated or unrecognized executable." }
        let m = Array(b.prefix(4))
        if m == [0xce,0xfa,0xed,0xfe] || m == [0xcf,0xfa,0xed,0xfe] {
            let cpu = uint32(b,4,big:false)
            if cpu == 12 { return "ARMv7/ARM32 only: cannot execute directly on current 64-bit-only iOS. Recompilation from compatible source or a substantial new implementation is required." }
            if cpu == 0x0100000c { return "ARM64 present: inspect minimum OS, dependent libraries, symbols, entitlements and runtime crashes before deciding on repairs." }
            return "Little-endian Mach-O CPU type: \\(cpu)"
        }
        if m == [0xca,0xfe,0xba,0xbe] || m == [0xca,0xfe,0xba,0xbf] {
            let count = min(Int(uint32(b,4,big:true)), 32)
            let width = m[3] == 0xbf ? 32 : 20
            var cpus:[UInt32]=[]
            for i in 0..<count {
                let offset=8+i*width
                if offset+4 <= b.count { cpus.append(uint32(b,offset,big:true)) }
            }
            let arm64=cpus.contains(0x0100000c)
            let arm32=cpus.contains(12)
            return "Fat Mach-O: ARM64=\\(arm64), ARM32=\\(arm32). " + (arm64 ? "ARM64 slice exists; further compatibility checks required." : "No ARM64 slice found; changing the IPA metadata cannot make this run on newer iOS.")
        }
        return "Unknown or unsupported executable format."
    }
    static func generateReport(ipa: URL) throws -> URL {
        let archive = try Archive(url: ipa, accessMode: .read)
        let entries = Array(archive)
        guard entries.count < 40000 else { throw NSError(domain:"Reconstruction",code:1,userInfo:[NSLocalizedDescriptionKey:"Archive exceeds inspection limit"]) }
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("LocalCoder-Binary-Evidence-"+UUID().uuidString+".txt")
        var report = ["LOCALCODER BINARY EVIDENCE", "Evidence is NOT the original source code.", "Entries: \(entries.count)"]
        let allowed = [".plist",".strings",".storyboardc",".nib",".xib",".json",".html",".js",".css",".metallib",".framework",".dylib",".car",".png",".jpg",".wav",".caf",".mp3",".map"]
        for entry in entries where entry.type == .file {
            let path = entry.path
            if allowed.contains(where: { path.lowercased().hasSuffix($0) }) { report.append("Resource: "+path) }
        }
        if let manifest = entries.first(where:{$0.path.hasPrefix("Payload/") && $0.path.hasSuffix(".app/Info.plist")}) {
            var bytes = Data()
            _ = try archive.extract(manifest,consumer:{ bytes.append($0) })
            if let info = try PropertyListSerialization.propertyList(from:bytes,format:nil) as? [String:Any] {
                for key in ["CFBundleIdentifier","CFBundleExecutable","CFBundleName","CFBundleShortVersionString","MinimumOSVersion"] {
                    report.append("\(key): \(info[key] ?? "absent")")
                }
            }
        }
        let binaries = entries.filter { $0.type == .file && !$0.path.contains(".framework/") && $0.uncompressedSize > 40000 && $0.uncompressedSize < 300_000_000 }
        var found = 0
        for entry in binaries.prefix(60) {
            var prefix = Data()
            _ = try archive.extract(entry,consumer:{ part in
                if prefix.count < 1_048_576 { prefix.append(part.prefix(1_048_576-prefix.count)) }
            })
            if prefix.count < 4 { continue }
            let magic = prefix.prefix(4).map { String(format:"%02x",$0) }.joined()
            guard ["cffaedfe","feedfacf","cafebabe","bebafeca"].contains(magic) else { continue }
            found += 1
            report.append("Mach-O binary: \(entry.path) (\(entry.uncompressedSize) bytes)")
            var runs = [String]()
            var current = [UInt8]()
            func flush() {
                if current.count >= 7 && current.count <= 180 && runs.count < 100 {
                    let value = String(decoding:current,as:UTF8.self)
                    if value.rangeOfCharacter(from:.letters) != nil { runs.append(value) }
                }
                current.removeAll(keepingCapacity:true)
            }
            for byte in prefix {
                if byte >= 32 && byte <= 126 { current.append(byte) } else { flush() }
            }
            flush()
            report += runs.prefix(100).map { "Binary text evidence: "+$0 }
        }
        report.append("Mach-O files inspected: \(found)")
        report.append("Only the first 1 MiB of each eligible binary was scanned for printable strings.")
        report.append("Further disassembly, control-flow recovery and native source regeneration require a dedicated analyzer and human validation.")
        try report.joined(separator:"\n").write(to:out,atomically:true,encoding:.utf8)
        return out
    }
}
