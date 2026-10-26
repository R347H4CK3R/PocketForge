import Foundation
import CoreFoundation
import Darwin
import ZIPFoundation

/// Experimental bridge to the CCDriver/CCJob ABI in Nyxian 0.11.4.
/// The compiler runs in-process; this does not sign or run the produced executable.
enum PocketNativeBuild {
    typealias DriverCreate = @convention(c) (CFAllocator?, CFArray, UInt8) -> UnsafeMutableRawPointer?
    typealias DriverJobs = @convention(c) (UnsafeMutableRawPointer) -> Unmanaged<CFArray>?
    typealias JobType = @convention(c) (UnsafeMutableRawPointer) -> UInt8
    typealias JobArgs = @convention(c) (UnsafeMutableRawPointer) -> Unmanaged<CFArray>?
    typealias Execute = @convention(c) (UnsafeMutableRawPointer, UnsafeMutablePointer<Unmanaged<CFArray>?>?, UnsafeMutablePointer<Unmanaged<CFString>?>?) -> Bool

    static func failure(_ message: String) -> NSError {
        NSError(domain: "PocketForge.NativeBuild", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    static func sdkURL() throws -> URL {
        let fm = FileManager.default
        let support = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let candidates = [support.appendingPathComponent("iPhoneOS.sdk"),
                          Bundle.main.bundleURL.appendingPathComponent("BundledSDK/iPhoneOS.sdk")]
        for sdk in candidates {
            let metadata = ["SDKSettings.json", "SDKSettings.plist"].contains {
                fm.fileExists(atPath: sdk.appendingPathComponent($0).path)
            }
            if metadata && fm.fileExists(atPath: sdk.appendingPathComponent("usr/include").path) { return sdk }
        }
        throw failure("No usable iPhoneOS SDK folder found. Import an SDK under Compiler Setup.")
    }

    static func build(source: String, name: String, isSwift: Bool) throws -> URL {
        let valid = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_"))
        guard !name.isEmpty, name.unicodeScalars.allSatisfy({ valid.contains($0) }) else {
            throw failure("Project name must contain only letters, digits and underscores.")
        }
        guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw failure("Source is empty.") }
        let sdk = try sdkURL()
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("PocketForgeBuild-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let resources = Bundle.main.bundleURL.appendingPathComponent("NyxianResources")
        for file in ["swift.zip", "lib.zip"] {
            let zip = resources.appendingPathComponent(file)
            guard fm.fileExists(atPath: zip.path) else { throw failure("Missing bundled compiler resource: " + file) }
            try fm.unzipItem(at: zip, to: root)
        }
        let swiftRoot = root.appendingPathComponent("swift")
        let clangResource = swiftRoot.appendingPathComponent("clang")
        let runtime = root.appendingPathComponent("lib")
        let sourceFile = root.appendingPathComponent(isSwift ? "App.swift" : "App.m")
        try source.write(to: sourceFile, atomically: true, encoding: .utf8)
        let payload = root.appendingPathComponent("Payload", isDirectory: true)
        let app = payload.appendingPathComponent(name + ".app", isDirectory: true)
        try fm.createDirectory(at: app, withIntermediateDirectories: true)
        let executable = app.appendingPathComponent(name)
        let clangFlags = ["-target", "arm64-apple-ios26.0", "-isysroot", sdk.path,
                          "-resource-dir", clangResource.path, "-L" + runtime.path, "-lclang_rt.ios",
                          "-fmodules", "-fobjc-arc", "-framework", "Foundation", "-framework", "UIKit"]
        let arguments: [String]
        if isSwift {
            arguments = ["-target", "arm64-apple-ios26.0", "-Xllvm", "-aarch64-use-tbi",
                         "-Xfrontend", "-enable-objc-interop", "-sdk", sdk.path,
                         "-resource-dir", swiftRoot.path, "-module-cache-path", root.appendingPathComponent("ModuleCache").path,
                         "-parse-as-library", "-module-name", name, sourceFile.path, "-o", executable.path]
        } else {
            arguments = clangFlags + [sourceFile.path, "-o", executable.path]
        }
        guard let frameworks = Bundle.main.privateFrameworksURL else { throw failure("Framework directory missing.") }
        let library = frameworks.appendingPathComponent("CoreCompiler.framework/CoreCompiler")
        guard let handle = dlopen(library.path, RTLD_NOW | RTLD_LOCAL) else {
            throw failure("Could not load CoreCompiler: " + (dlerror().map { String(cString: $0) } ?? "unknown error"))
        }
        defer { dlclose(handle) }
        func symbol<T>(_ name: String, _ type: T.Type) throws -> T {
            guard let ptr = dlsym(handle, name) else { throw failure("Compiler API unavailable: " + name) }
            return unsafeBitCast(ptr, to: type)
        }
        let create = try symbol("CCDriverCreate", DriverCreate.self)
        let jobsForDriver = try symbol("CCDriverCreateJobs", DriverJobs.self)
        let jobType = try symbol("CCJobGetType", JobType.self)
        let jobArguments = try symbol("CCJobGetArguments", JobArgs.self)
        let execute = try symbol("CCJobExecuteJob", Execute.self)
        var compilerJobs = 0
        var linkerJobs = 0
        func runDriver(_ args: [String], _ driverType: UInt8, _ depth: Int) throws {
            guard depth <= 2 else { throw failure("Compiler produced too many nested driver jobs.") }
            guard let driver = create(kCFAllocatorDefault, args as CFArray, driverType) else { throw failure("Compiler driver creation failed.") }
            defer { Unmanaged<AnyObject>.fromOpaque(driver).release() }
            guard let jobs = jobsForDriver(driver)?.takeRetainedValue() as NSArray?, jobs.count > 0 else {
                throw failure("Compiler driver returned no jobs. Check SDK and compiler compatibility.")
            }
            for job in jobs {
                let ptr = Unmanaged.passUnretained(job as AnyObject).toOpaque()
                let kind = jobType(ptr)
                if kind == 1 {
                    guard let nested = jobArguments(ptr)?.takeUnretainedValue() as? [String] else { throw failure("Nested linker driver arguments unavailable.") }
                    try runDriver(nested + clangFlags, 0, depth + 1)
                    continue
                }
                guard kind == 0 || kind == 2 || kind == 4 else { throw failure("Unsupported compiler job type: " + String(kind)) }
                if kind == 4 { linkerJobs += 1 } else { compilerJobs += 1 }
                var diagnostics: Unmanaged<CFArray>?
                var mainSource: Unmanaged<CFString>?
                let success = execute(ptr, &diagnostics, &mainSource)
                let messages = diagnostics?.takeRetainedValue()
                _ = mainSource?.takeRetainedValue()
                if !success {
                    throw failure("Compiler job " + String(kind) + " failed. " + (messages.map { String(describing: $0) } ?? "No diagnostics returned."))
                }
            }
        }
        try runDriver(arguments, isSwift ? 1 : 0, 0)
        guard compilerJobs > 0 && linkerJobs > 0 else { throw failure("Build did not run both compiler and linker jobs.") }
        guard let header = try? Data(contentsOf: executable, options: .mappedIfSafe),
              header.count >= 32, Array(header.prefix(4)) == [0xcf, 0xfa, 0xed, 0xfe],
              Array(header[4..<8]) == [0x0c, 0x00, 0x00, 0x01],
              Array(header[12..<16]) == [0x02, 0x00, 0x00, 0x00] else {
            throw failure("Linker did not produce an ARM64 executable Mach-O.")
        }
        let plist: [String: Any] = ["CFBundleIdentifier": "dev.pocketforge.generated." + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased(),
            "CFBundleName": name, "CFBundleExecutable": name, "CFBundlePackageType": "APPL",
            "CFBundleVersion": "1", "CFBundleShortVersionString": "1.0", "MinimumOSVersion": "26.0",
            "UILaunchScreen": [:]]
        let plistData = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try plistData.write(to: app.appendingPathComponent("Info.plist"), options: .atomic)
        let ipa = fm.temporaryDirectory.appendingPathComponent(name + "-" + UUID().uuidString + "-unsigned.ipa")
        try fm.zipItem(at: payload, to: ipa, shouldKeepParent: true)
        return ipa
    }
}
