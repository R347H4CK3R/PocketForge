import Foundation
import ZIPFoundation

enum ForgeTaskKind: String {
    case inspectIPA = "Inspect IPA"
    case diagnoseLog = "Diagnose log"
    case rebuildWeb = "Build web app"
    case generateNative = "Generate native source"
    case unsupportedNative = "Native executable port"
    case general = "General development"
}
struct ForgeTaskPlan {
    let kind: ForgeTaskKind
    let steps: [String]
    let capability: String
    var report: String { "Task: \(kind.rawValue)\n" + steps.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator:"\n") + "\nCapability: " + capability }
}
enum ForgeTaskRouter {
    static func classify(_ request: String, attachments: [String]) -> ForgeTaskPlan {
        let q=request.lowercased()
        let hasIPA=attachments.contains { $0.lowercased().hasSuffix(".ipa") }
        let hasLog=attachments.contains { $0.lowercased().hasSuffix(".log") || $0.lowercased().hasSuffix(".ips") || $0.lowercased().hasSuffix(".crash") }
        if hasIPA || q.contains("ipa") || q.contains("port") || q.contains("older iphone") {
            return ForgeTaskPlan(kind:.inspectIPA,steps:["Read archive metadata and Mach-O architectures","Check ARM64 availability and resource inventory","Correlate any imported crash log","Identify source or equivalent implementation requirements","Only apply validated fixes; do not mislabel a starter shell as a repaired game"],capability:"IPA inspection and limited metadata edits are available. General native game conversion and execution are not verified.")
        }
        if hasLog || q.contains("crash") || q.contains("diagnos") {
            return ForgeTaskPlan(kind:.diagnoseLog,steps:["Read log and identify concrete error signatures","Match reported app version and relevant binaries","Recommend an evidence-backed repair","Request source only if required for executable changes"],capability:"Diagnostic analysis available; native binary patching is not general-purpose.")
        }
        if q.contains("swift") || q.contains("native") || q.contains("objective-c") {
            return ForgeTaskPlan(kind:.generateNative,steps:["Generate editable SwiftUI source","Validate source shape","Export native project","Check installed compiler and SDK before promising an IPA"],capability:"Native source export works; on-device compile/link is not verified.")
        }
        if q.contains("web") || q.contains("html") || q.contains("app") || q.contains("game") {
            return ForgeTaskPlan(kind:.rebuildWeb,steps:["Generate self-contained HTML/JavaScript implementation","Preview in an ephemeral WebKit runtime","Inspect resulting behavior","Package with precompiled WebKit shell if accepted"],capability:"WebKit app preview and unsigned shell packaging supported.")
        }
        return ForgeTaskPlan(kind:.general,steps:["Break down request into verifiable tasks","Select supported tool","Report unsupported dependencies explicitly"],capability:"Cannot promise arbitrary external actions or unverified native execution.")
    }
}
