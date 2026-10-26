import Foundation
import UniformTypeIdentifiers
import ZIPFoundation

struct ChatAttachment: Identifiable {
    let id = UUID()
    let name: String
    let url: URL
    let context: String
}
@MainActor @Observable final class AttachmentStore {
    var items: [ChatAttachment] = []
    var error = ""
    func add(_ url: URL) {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            guard items.count < 5 else { error = "Maximum five attachments per message."; return }
            let data = try Data(contentsOf: url)
            guard data.count <= 12_000_000 else { error = "File exceeds the 12 MB attachment limit."; return }
            let name = url.lastPathComponent
            let ext = url.pathExtension.lowercased()
            var description = "File: \(name), \(data.count) bytes."
            if ["swift","m","mm","h","c","cpp","txt","log","json","md","xml","plist","crash","ips"].contains(ext),
               let text = String(data:data,encoding:.utf8) {
                description += "\nContents (truncated):\n" + String(text.prefix(18000))
            } else if ["ipa","zip"].contains(ext) {
                let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".zip")
                try data.write(to:tmp)
                defer { try? FileManager.default.removeItem(at:tmp) }
                let archive = try Archive(url:tmp,accessMode:.read)
                let names = Array(archive).map(\.path)
                description += "\nArchive entries: \(names.count)\n" + names.prefix(100).joined(separator:"\n")
            } else {
                description += "\nBinary file: content not directly readable by the local text model."
            }
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+"-"+name)
            try data.write(to:tmp,options:.atomic)
            items.append(ChatAttachment(name:name,url:tmp,context:description))
            error = ""
        } catch { self.error = "Attachment failed: \(error.localizedDescription)" }
    }
    func remove(_ id: UUID) {
        if let item = items.first(where:{$0.id == id}) { try? FileManager.default.removeItem(at:item.url) }
        items.removeAll(where:{$0.id == id})
    }
    func consumeContext() -> String {
        let result = items.map(\.context).joined(separator:"\n\n")
        for item in items { try? FileManager.default.removeItem(at:item.url) }
        items.removeAll()
        return result
    }
}
