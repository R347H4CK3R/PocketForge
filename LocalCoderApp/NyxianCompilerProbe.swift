import Foundation
import Darwin
import CoreFoundation

/// Dynamic ABI wrapper for Nyxian CoreCompiler. Does not run a job when SDK is unavailable.
/// The ABI contract is based on Nyxian's CCSDK.h and CCJob.h.
enum NyxianCompilerProbe {
    typealias CreateSDK = @convention(c) (CFAllocator?, CFURL) -> UnsafeMutableRawPointer?
    typealias CopyVersion = @convention(c) (UnsafeMutableRawPointer) -> Unmanaged<CFString>?
    typealias CreateJob = @convention(c) (CFAllocator?, UInt8, CFArray) -> UnsafeMutableRawPointer?
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
        let locations = (sdkURL.map { [$0] } ?? []) + [Bundle.main.bundleURL.appendingPathComponent("BundledSDK/iPhoneOS.sdk", isDirectory: true)] + [
            root.appendingPathComponent("SDK", isDirectory: true),
            root.appendingPathComponent("SDKs", isDirectory: true),
            root.appendingPathComponent("iPhoneOS.sdk", isDirectory: true)
        ]
        guard let sdkPath = locations.first(where: {
            let metadata = ["SDKSettings.json", "SDKSettings.plist"].contains { file in
                FileManager.default.fileExists(atPath: $0.appendingPathComponent(file).path)
            }
            return metadata && FileManager.default.fileExists(atPath: $0.appendingPathComponent("usr/include").path)
        }) else { return "No unpacked iPhoneOS SDK found. Import a folder with SDK metadata and headers." }
        return "SDK folder located at " + sdkPath.lastPathComponent + ". Compiler symbols are present. Use the native source editor to attempt a build; device compilation is not yet verified."
    }
}
