import Foundation
import Darwin
import CoreFoundation

/// Dynamic ABI wrapper for Nyxian CoreCompiler. Does not run a job when SDK is unavailable.
/// The ABI contract is based on Nyxian's CCSDK.h and CCJob.h.
enum NyxianCompilerProbe {
    typealias CreateSDK = @convention(c) (CFAllocator?, CFURL) -> UnsafeMutableRawPointer?
    typealias CopyVersion = @convention(c) (UnsafeMutableRawPointer) -> Unmanaged<CFString>?
    typealias CreateJob = @convention(c) (CFAllocator?, UInt8, CFArray, CFArray, CFURL) -> UnsafeMutableRawPointer?
    typealias ExecuteJob = @convention(c) (UnsafeMutableRawPointer, UnsafeMutablePointer<Unmanaged<CFArray>?>?, UnsafeMutablePointer<Unmanaged<CFString>?>?) -> Bool

    static func inspect(sdkURL: URL? = nil) -> String {
        guard let frameworks = Bundle.main.privateFrameworksURL else { return "Private frameworks unavailable" }
        let dylib = frameworks.appendingPathComponent("CoreCompiler.framework/CoreCompiler")
        guard let handle = dlopen(dylib.path, RTLD_NOW | RTLD_LOCAL) else {
            return "Compiler load failed: " + String(cString: dlerror())
        }
        defer { dlclose(handle) }
        let names = ["CCSDKCreateWithDirectoryURL", "CCSDKCopyVersion", "CCJobCreate", "CCJobExecuteJob", "CCCompilerJobExecute", "CCSwiftCompilerJobExecute", "CCLinkerJobExecute"]
        let missing = names.filter { dlsym(handle, $0) == nil }
        guard missing.isEmpty else { return "Missing compiler entry points: " + missing.joined(separator: ", ") }
        let root = Bundle.main.bundleURL.appendingPathComponent("NyxianResources")
        let locations = (sdkURL.map { [$0] } ?? []) + [
            root.appendingPathComponent("SDK", isDirectory: true),
            root.appendingPathComponent("SDKs", isDirectory: true),
            root.appendingPathComponent("iPhoneOS.sdk", isDirectory: true)
        ]
        guard let sdkPath = locations.first(where: { FileManager.default.fileExists(atPath: $0.appendingPathComponent("SDKSettings.plist").path) }) else {
            return "Compiler ABI symbols verified. No unpacked iOS SDK with SDKSettings.plist was found; compilation blocked safely. The bundled resource pack is not automatically an initialized SDK."
        }
        guard let raw = dlsym(handle, "CCSDKCreateWithDirectoryURL") else { return "SDK initializer unavailable" }
        let create = unsafeBitCast(raw, to: CreateSDK.self)
        guard let sdk = create(kCFAllocatorDefault, sdkPath as CFURL) else {
            return "SDK directory found, but Nyxian rejected initialization."
        }
        defer { Unmanaged<AnyObject>.fromOpaque(sdk).release() }
        let copy = unsafeBitCast(dlsym(handle, "CCSDKCopyVersion")!, to: CopyVersion.self)
        let version = copy(sdk)?.takeRetainedValue() as String? ?? "unknown"
        return "Nyxian SDK initialized: " + version + ". Compiler job APIs found. Native compilation/linking still requires a configured job and device smoke tests."
    }
}
