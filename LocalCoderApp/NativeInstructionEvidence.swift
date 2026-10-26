import Foundation
import ZIPFoundation

/// Bounded native instruction inspection; this is disassembly evidence, not decompiled source.
enum NativeInstructionEvidence {
    private static func word(_ b:[UInt8],_ p:Int,_ big:Bool) -> UInt32 {
        guard p+4 <= b.count else { return 0 }
        if big { return (UInt32(b[p]) << 24)|(UInt32(b[p+1]) << 16)|(UInt32(b[p+2]) << 8)|UInt32(b[p+3]) }
        return UInt32(b[p])|(UInt32(b[p+1]) << 8)|(UInt32(b[p+2]) << 16)|(UInt32(b[p+3]) << 24)
    }
    static func analyze(_ data: Data) -> String {
        let b=Array(data.prefix(1_048_576))
        guard b.count >= 32 else { return "Executable too short for instruction analysis." }
        let magic=Array(b.prefix(4))
        let arm64=magic == [0xcf,0xfa,0xed,0xfe] && word(b,4,false) == 0x0100000c
        let arm32=magic == [0xce,0xfa,0xed,0xfe] && word(b,4,false) == 12
        guard arm64 || arm32 else { return "Unsupported executable slice. ARM64/ARM32 thin Mach-O required; fat binaries need slice extraction." }
        var lines=["Instruction evidence: \(arm64 ? "ARM64" : "ARM32")", "Decoder covers a bounded subset; unknown instructions are emitted as .word.", "This is not C pseudocode or recovered original source."]
        let commands=Int(word(b,16,false))
        var cursor=arm64 ? 32 : 28
        var textOffset:Int?
        for _ in 0..<min(commands,128) {
            guard cursor+8 <= b.count else { break }
            let cmd=word(b,cursor,false)
            let length=Int(word(b,cursor+4,false))
            guard length>=8 && cursor+length<=b.count else { break }
            if (arm64 && cmd == 0x19) || (arm32 && cmd == 0x1) {
                let firstSection=cursor+(arm64 ? 72 : 56)
                let sectionWidth=arm64 ? 80 : 68
                let count=Int(word(b,cursor+(arm64 ? 64 : 48),false))
                for i in 0..<min(count,100) {
                    let p=firstSection+i*sectionWidth
                    guard p+sectionWidth<=cursor+length else { break }
                    let name=String(decoding:b[p..<(p+16)].prefix(while:{$0 != 0}),as:UTF8.self)
                    if name=="__text" {
                        let offset=Int(word(b,p+(arm64 ? 48 : 40),false))
                        if offset < b.count { textOffset=offset }
                    }
                }
            }
            cursor+=length
        }
        guard let start=textOffset else { return lines.joined(separator:"\n")+"\nNo __text section found in scanned bytes." }
        for i in 0..<min(512,(b.count-start)/4) {
            let pos=start+i*4
            let instruction=word(b,pos,false)
            var mnemonic=String(format:".word 0x%08X",instruction)
            if arm64 {
                if instruction == 0xd65f03c0 { mnemonic="ret" }
                else if instruction == 0xd503201f { mnemonic="nop" }
                else if instruction & 0xfc000000 == 0x14000000 || instruction & 0xfc000000 == 0x94000000 {
                    var relative=Int(instruction & 0x03ffffff)
                    if relative & 0x02000000 != 0 { relative -= 0x04000000 }
                    let name=instruction & 0xfc000000 == 0x94000000 ? "bl" : "b"
                    mnemonic=String(format:"%@ 0x%X",name,pos+relative*4)
                } else if instruction & 0xfffffc1f == 0xd61f0000 { mnemonic="br register" }
            } else {
                if instruction & 0x0ffffff0 == 0x012fff10 { mnemonic="bx register" }
                else if instruction & 0x0e000000 == 0x0a000000 {
                    var relative=Int(instruction & 0x00ffffff)
                    if relative & 0x00800000 != 0 { relative -= 0x01000000 }
                    let name=instruction & 0x01000000 != 0 ? "bl" : "b"
                    mnemonic=String(format:"%@ 0x%X",name,pos+8+relative*4)
                }
            }
            lines.append(String(format:"0x%08X: %@",pos,mnemonic))
        }
        lines.append("Branch targets are file-relative estimates and are not reconstructed functions.")
        return lines.joined(separator:"\n")
    }
    static func export(from ipa:URL) throws -> URL {
        let archive=try Archive(url:ipa,accessMode:.read)
        let manifests=Array(archive).filter {$0.path.hasPrefix("Payload/") && $0.path.hasSuffix(".app/Info.plist")}
        guard manifests.count == 1,let manifest=manifests.first else {throw NSError(domain:"PocketForge",code:30,userInfo:[NSLocalizedDescriptionKey:"Expected one iOS app manifest"])}
        var plist=Data()
        _=try archive.extract(manifest,consumer:{plist.append($0)})
        guard let details=try PropertyListSerialization.propertyList(from:plist,format:nil) as? [String:Any],
              let executable=details["CFBundleExecutable"] as? String else {throw NSError(domain:"PocketForge",code:31,userInfo:[NSLocalizedDescriptionKey:"Executable identity missing"])}
        let binaryPath=String(manifest.path.dropLast("Info.plist".count))+executable
        guard let binary=archive.first(where:{$0.path==binaryPath}) else {throw NSError(domain:"PocketForge",code:32,userInfo:[NSLocalizedDescriptionKey:"Mach-O file missing"])}
        var bytes=Data()
        _=try archive.extract(binary,consumer:{part in if bytes.count < 1_048_576 { bytes.append(part.prefix(1_048_576-bytes.count)) }})
        let text=analyze(bytes)
        let out=FileManager.default.temporaryDirectory.appendingPathComponent("PocketForge-Instruction-Evidence-"+UUID().uuidString+".txt")
        try text.write(to:out,atomically:true,encoding:.utf8)
        return out
    }
}
