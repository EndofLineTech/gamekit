import CryptoKit
import Darwin
import Foundation

/// Component revisions share the Wine/prefix ABI; selecting one never rewrites
/// an environment's base-engine identity or its saved installation state.
public enum RuntimeRevision: String, Codable, Sendable, CaseIterable {
    case original
    case textInput1 = "text-input-1"
    case driverVersion1 = "driver-version-1"

    public var title: String {
        switch self {
        case .original: "Sikarugir 10.0 revision 6 (original)"
        case .textInput1: "Sikarugir 10.0 revision 6 + Gamekit text-input 1"
        case .driverVersion1: "Sikarugir 10.0 revision 6 + text-input 1 + Helldivers driver compatibility"
        }
    }
    public var profile: RuntimeProfile {
        switch self {
        case .original: .sikarugir
        case .textInput1: .sikarugirTextInput1
        case .driverVersion1: .sikarugirDriverVersion1
        }
    }
}

public struct RuntimeProfile: Sendable {
    public let identity: RuntimeIdentity
    public let bundlePath: String
    public let wineVersionOutput: String
    public let hashes: [String: String]
    public let revision: RuntimeRevision

    public init(identity: RuntimeIdentity, bundlePath: String, wineVersionOutput: String,
                hashes: [String: String], revision: RuntimeRevision = .original) {
        self.identity = identity; self.bundlePath = bundlePath; self.wineVersionOutput = wineVersionOutput
        self.hashes = hashes; self.revision = revision
    }

    public static var sikarugirTextInput1: RuntimeProfile {
        var hashes = sikarugir.hashes
        hashes["Contents/SharedSupport/wine/lib/wine/x86_64-windows/msctf.dll"] =
            "bb8db266526cff89c2bc6a436482b24c632c13596c1864adb4cb2e42e58fca8b"
        return RuntimeProfile(identity: sikarugir.identity,
            bundlePath: "Runtimes/sikarugir10.0_6-d3dmetal4.0b2-text-input1/Template-1.0.11.app",
            wineVersionOutput: sikarugir.wineVersionOutput, hashes: hashes, revision: .textInput1)
    }

    static let driverShimRelative = "Contents/SharedSupport/wine/lib/gamekit/helldivers-dxgi.dll"
    static let driverOriginalRelative = "Contents/SharedSupport/wine/lib/wine/x86_64-windows/dxgm.dll"
    public static var sikarugirDriverVersion1: RuntimeProfile {
        var hashes = sikarugirTextInput1.hashes
        hashes[driverShimRelative] = "5ccd55cf94faaab72dcdef651aaccc7907c3eef46d0ecb1cb0f5de204940d2b2"
        hashes[driverOriginalRelative] = "5e80d3584e304ae1258aa13a1cf12830641dc2694988e670b7c7b5749f215c5c"
        return RuntimeProfile(identity: sikarugir.identity,
            bundlePath: "Runtimes/sikarugir10.0_6-d3dmetal4.0b2-driver-version1/Template-1.0.11.app",
            wineVersionOutput: sikarugir.wineVersionOutput, hashes: hashes, revision: .driverVersion1)
    }

    public static let sikarugir = RuntimeProfile(
        identity: RuntimeIdentity(provider: "Sikarugir", distribution: "10.0_6", wine: "10.0", graphics: "4.0b2"),
        bundlePath: "Runtimes/sikarugir10.0_6-d3dmetal4.0b2/Template-1.0.11.app",
        wineVersionOutput: "wine-10.0 (Sikarugir)",
        hashes: [
            "Contents/SharedSupport/wine/bin/wine": "1b992a3e0bc5f2a058a24f923832aaa6e464d44766fb0ad13054797e02060d10",
            "Contents/SharedSupport/wine/bin/wineserver": "6dfe1f9d2d8a67cc6a09a57966f5ef88fd461abe7321d6fb0d4a1672e8ff0350",
            "Contents/SharedSupport/wine/lib/external/D3DMetal.framework/Versions/A/D3DMetal": "f5b56df1b8fe8b364dd9530651a3769c8aed948bd343be3b4510604d503e2bad",
            "Contents/SharedSupport/wine/lib/external/libd3dshared.dylib": "1582e7ceef7f495df4bebf7f06a49aef130233f8a2e9a8971e35affafeb76ec0",
            "Contents/SharedSupport/wine/lib/wine/x86_64-windows/d3d11.dll": "303b2bb41efa30c890e2e93d39c3d3c565c8557e069eee832f2cb8a37bd4ec26",
            "Contents/SharedSupport/wine/lib/wine/x86_64-windows/d3d12.dll": "1b7a02cb37ec6b484e2aaa76b5ec9cbb47e63aeec29dbe087d5d1589a3347cfb",
            "Contents/SharedSupport/wine/lib/wine/x86_64-windows/dxgi.dll": "522a8b37216afb09e614489d88a74118076f4d7e08d2b289df6a6eb6f3e817af",
        ]
    )
}

public enum GraphicsBackend: String, Codable, Sendable, CaseIterable {
    case automatic, metal3, dxvk, dxmt

    /// Payload/probe availability is not game qualification. The alternative
    /// renderers remain developer-only until the recorded game blockers clear.
    public var qualifiedForGames: Bool { self == .automatic || self == .metal3 }

    public var title: String {
        switch self {
        case .automatic: "Automatic (Apple default)"
        case .metal3: "Metal 3 compatibility"
        case .dxvk: "DXVK (Direct3D 10/11)"
        case .dxmt: "DXMT (Direct3D 10/11)"
        }
    }
}

// Source compatibility for the original Apple-only settings API.
public typealias D3DMetalBackend = GraphicsBackend

public struct RuntimeLayout: Sendable {
    public let dataRoot: URL
    public let profile: RuntimeProfile
    fileprivate let selectedBundle: URL?
    public let identityHelper: URL?
    public let graphicsBackend: D3DMetalBackend
    public init(dataRoot: URL = EnvironmentStore.applicationSupportRoot, profile: RuntimeProfile = .sikarugir, bundle: URL? = nil,
                identityHelper: URL? = nil, graphicsBackend: D3DMetalBackend = .automatic) {
        self.dataRoot = dataRoot; self.profile = profile; selectedBundle = bundle
        self.graphicsBackend = graphicsBackend
        self.identityHelper = identityHelper ?? (Bundle.main.bundleIdentifier == "tech.endofline.gamekit"
            ? Bundle.main.privateFrameworksURL?.appendingPathComponent("WineGameIdentity.dylib") : nil)
    }
    public var hasGameIdentityHelper: Bool {
        guard let identityHelper else { return false }
        return RuntimeDetector.containedRegularFile(identityHelper, root: identityHelper.deletingLastPathComponent())
    }
    public var bundle: URL { selectedBundle ?? dataRoot.appendingPathComponent(profile.bundlePath) }
    public var engine: URL { bundle.appendingPathComponent("Contents/SharedSupport/wine") }
    public var wine: URL { engine.appendingPathComponent("bin/wine") }
    public var wineserver: URL { engine.appendingPathComponent("bin/wineserver") }
    public var frameworks: URL { bundle.appendingPathComponent("Contents/Frameworks") }
    public var graphics: URL { engine.appendingPathComponent("lib/external/D3DMetal.framework") }
    public var launchersRoot: URL {
        let root = dataRoot.appendingPathComponent("Launchers")
        return profile.revision == .original ? root : root.appendingPathComponent("Revisions/\(profile.revision.rawValue)")
    }
    public var steamApplicationBundle: URL { launchersRoot.appendingPathComponent("Windows Steam.app") }
    public var gameApplicationsRoot: URL { launchersRoot.appendingPathComponent("Games") }
    var defaultLibraryPath: String { "\(engine.path)/lib:\(frameworks.path):\(frameworks.path)/GStreamer.framework/Libraries" }
    var dxvkLibraryPath: String { "\(frameworks.path)/moltenvkcx:" + defaultLibraryPath }

    public func environment(prefix: URL? = nil, session: String? = nil,
                            inheriting inherited: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        let allowed = Set(["HOME", "USER", "LOGNAME", "TMPDIR", "PATH", "LANG", "LC_ALL", "LC_CTYPE", "TZ"])
        var result = inherited.filter { allowed.contains($0.key) }
        result["PATH"] = result["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        result["WINEDEBUG"] = "-all"
        result["WINEARCH"] = "win64"
        // GPTK documents this opt-in on macOS 15+. The validated macOS 27
        // translator executes AVX/AVX2; publish those capabilities to games.
        result["ROSETTA_ADVERTISE_AVX"] = "1"
        if profile.revision == .driverVersion1 {
            result["GAMEKIT_DXGI_ORIGINAL"] = "Z:" + bundle.appendingPathComponent(RuntimeProfile.driverOriginalRelative).path.replacingOccurrences(of: "/", with: "\\")
        }
        // Apple documents this per-process fallback inside the same D3DMetal
        // payload. An explicit saved/session choice selects the fallback;
        // automatic mode leaves Apple's default in control.
        if graphicsBackend != .automatic { result["D3DM_MTL4"] = "0" }
        // Steam installs the genuine VC++ redistributables. Prefer that coherent
        // DLL family when present: builtin version resources can make Unreal's
        // bootstrapper repeatedly request an already-installed runtime.
        result["WINEDLLOVERRIDES"] = "msvcp140,msvcp140_1,msvcp140_2,msvcp140_atomic_wait,vcruntime140,vcruntime140_1,concrt140=n,b"
        result["DYLD_FALLBACK_LIBRARY_PATH"] = defaultLibraryPath
        result["DYLD_FALLBACK_FRAMEWORK_PATH"] = "\(engine.path)/lib/external:\(frameworks.path)"
        if let prefix { result["WINEPREFIX"] = prefix.path }
        if let session { result["GAMEKIT_SESSION_ID"] = session }
        if let prefix, session != nil, hasGameIdentityHelper, let identityHelper {
            result["DYLD_INSERT_LIBRARIES"] = identityHelper.path
            result["GAMEKIT_GAME_NAMES_FILE"] = GameDockNames.url(root: dataRoot, prefix: prefix).path
        }
        return result
    }
}

public struct RuntimeHostFacts: Sendable {
    public let macOSMajorVersion: Int
    public let architecture: HostArchitecture
    public let availableBytes: Int64?
    public init(macOSMajorVersion: Int, architecture: HostArchitecture, availableBytes: Int64?) {
        self.macOSMajorVersion = macOSMajorVersion; self.architecture = architecture; self.availableBytes = availableBytes
    }
    public static func current(at url: URL) -> RuntimeHostFacts {
        var arm64: Int32 = 0
        var size = MemoryLayout.size(ofValue: arm64)
        let architecture: HostArchitecture = sysctlbyname("hw.optional.arm64", &arm64, &size, nil, 0) == 0
            ? (arm64 == 1 ? .arm64 : .x86_64) : .unknown
        var volume = url
        while !FileManager.default.fileExists(atPath: volume.path), volume.path != "/" {
            volume.deleteLastPathComponent()
        }
        let values = try? volume.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        let available = values?.volumeAvailableCapacityForImportantUsage ?? values?.volumeAvailableCapacity.map(Int64.init)
        return RuntimeHostFacts(macOSMajorVersion: ProcessInfo.processInfo.operatingSystemVersion.majorVersion,
                                architecture: architecture, availableBytes: available)
    }
}

public enum RuntimeCheckStatus: Sendable { case passed, failed, unknown }
public struct RuntimeCheck: Sendable {
    public let prerequisite: Prerequisite
    public let status: RuntimeCheckStatus
    public let detail: String
    public init(prerequisite: Prerequisite, status: RuntimeCheckStatus, detail: String) {
        self.prerequisite = prerequisite; self.status = status; self.detail = detail
    }
}
public struct RuntimeReport: Sendable {
    public let checks: [RuntimeCheck]
    public init(checks: [RuntimeCheck]) { self.checks = checks }
    public var prerequisites: PrerequisiteObservation {
        let missing = checks.filter { $0.status == .failed }.map(\.prerequisite)
        if !missing.isEmpty { return .missing(missing) }
        return checks.contains { $0.status == .unknown } ? .notChecked : .ready
    }
}

public struct RuntimeDetector: Sendable {
    public static let minimumFreeBytes: Int64 = 15 * 1024 * 1024 * 1024
    private let execute: @Sendable (CommandRequest) async throws -> CommandResult
    public init() { execute = { try await ProcessExecutor().run($0) } }
    public init(execute: @escaping @Sendable (CommandRequest) async throws -> CommandResult) { self.execute = execute }

    public func detect(_ layout: RuntimeLayout, selection: RuntimeIdentity?,
                       host: RuntimeHostFacts? = nil) async throws -> RuntimeReport {
        let facts = host ?? RuntimeHostFacts.current(at: layout.dataRoot)
        let supported = PrototypeHostPolicy.failures(macOSMajorVersion: facts.macOSMajorVersion, architecture: facts.architecture).isEmpty
        var checks: [RuntimeCheck] = [.init(prerequisite: .supportedHost, status: supported ? .passed : .failed,
                                            detail: supported ? "Apple silicon / macOS 27" : "Outside the evaluated host scope")]
        if let bytes = facts.availableBytes {
            checks.append(.init(prerequisite: .diskSpace, status: bytes >= Self.minimumFreeBytes ? .passed : .failed,
                                detail: "\(bytes / (1024 * 1024 * 1024)) GiB available; 15 GiB working allowance"))
        } else {
            checks.append(.init(prerequisite: .diskSpace, status: .unknown, detail: "Disk capacity could not be checked"))
        }
        if supported {
            let translated = try? await execute(CommandRequest(executable: URL(fileURLWithPath: "/usr/bin/arch"),
                                                               arguments: ["-x86_64", "/usr/bin/uname", "-m"], timeout: 10, outputLimit: 4096))
            try Task.checkCancellation()
            let available = translated?.termination == .exited(0) && translated?.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines) == "x86_64"
            checks.append(.init(prerequisite: .rosetta, status: available ? .passed : .failed,
                                detail: available ? "Intel execution probe passed" : "Intel execution is unavailable"))
        } else {
            checks.append(.init(prerequisite: .rosetta, status: .unknown, detail: "Not executed on an unsupported host"))
        }
        let selected = selection == layout.profile.identity && Self.safeBundle(layout)
        var runtimeValid = selected, graphicsValid = selected
        var versionChecked = false
        if selected {
            for (relative, hash) in layout.profile.hashes {
                try Task.checkCancellation()
                let valid = Self.matches(layout.bundle.appendingPathComponent(relative), root: layout.bundle, hash: hash)
                if relative.contains("/bin/") || relative.hasSuffix("/msctf.dll") { runtimeValid = runtimeValid && valid }
                else { graphicsValid = graphicsValid && valid }
            }
            let dependencies = ["libinotify.0.dylib", "libfreetype.6.dylib", "libgnutls.30.dylib", "libSDL2-2.0.0.dylib",
                                "GStreamer.framework/Libraries/libgstreamer-1.0.0.dylib"]
            runtimeValid = runtimeValid && dependencies.allSatisfy {
                Self.containedRegularFile(layout.frameworks.appendingPathComponent($0), root: layout.bundle)
            }
            runtimeValid = runtimeValid && FileManager.default.isExecutableFile(atPath: layout.wine.path)
                && FileManager.default.isExecutableFile(atPath: layout.wineserver.path)
            let versionURL = layout.graphics.appendingPathComponent("Resources/version.plist")
            if Self.containedRegularFile(versionURL, root: layout.bundle),
               let data = try? Data(contentsOf: versionURL),
               let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
                graphicsValid = graphicsValid && plist["CFBundleVersion"] as? String == "4.0b2"
                    && plist["SourceVersion"] as? String == "33024000000000"
            } else { graphicsValid = false }
        }
        if runtimeValid && supported && checks.contains(where: { $0.prerequisite == .rosetta && $0.status == .passed }) {
            versionChecked = true
            let version = try? await execute(CommandRequest(executable: layout.wine, arguments: ["--version"],
                                                           environment: layout.environment(), workingDirectory: layout.engine,
                                                           timeout: 10, outputLimit: 4096))
            try Task.checkCancellation()
            runtimeValid = version?.termination == .exited(0)
                && version?.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines) == layout.profile.wineVersionOutput
        }
        if graphicsValid {
            let signature = try? await execute(CommandRequest(executable: URL(fileURLWithPath: "/usr/bin/codesign"),
                                                             arguments: ["--verify", "--deep", "--strict", layout.graphics.path],
                                                             timeout: 15, outputLimit: 4096))
            try Task.checkCancellation()
            graphicsValid = signature?.termination == .exited(0)
        }
        checks.append(.init(prerequisite: .runtime, status: runtimeValid ? (versionChecked ? .passed : .unknown) : .failed,
                            detail: runtimeValid ? (versionChecked ? layout.profile.revision.title : "Runtime files match; execution not checked")
                                : "Runtime selection, files, dependencies or version do not match"))
        checks.append(.init(prerequisite: .graphicsPayload, status: graphicsValid ? .passed : .failed,
                            detail: graphicsValid ? "Apple D3DMetal 4.0b2 integrity verified" : "Graphics payload does not match the validated recipe"))
        return RuntimeReport(checks: checks)
    }

    static func safeBundle(_ layout: RuntimeLayout) -> Bool {
        do {
            if layout.selectedBundle != nil {
                let bundle = try ManagedDirectory.canonicalRoot(layout.bundle)
                return try ManagedDirectory.openRoot(bundle, create: false) != nil
            }
            let root = try EnvironmentStore(root: layout.dataRoot).root
            guard var directory = try ManagedDirectory.openRoot(root, create: false) else { return false }
            for part in try RelativePath(layout.profile.bundlePath).components {
                guard let next = try directory.directory(part) else { return false }
                directory = next
            }
            return true
        } catch { return false }
    }

    static func containedRegularFile(_ url: URL, root: URL) -> Bool {
        let base = root.resolvingSymlinksInPath().standardizedFileURL.path
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL
        guard resolved.path.hasPrefix(base + "/") else { return false }
        return (try? resolved.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
    }
    static func matches(_ url: URL, root: URL, hash: String) -> Bool {
        guard containedRegularFile(url, root: root),
              let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 64 * 1024 * 1024,
              let bytes = try? Data(contentsOf: url) else { return false }
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() == hash
    }
}
