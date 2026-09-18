import Foundation

public enum SteamApplicationError: Error, Equatable { case invalidBundle, invalidRuntime }

struct GameApplicationIdentity: Sendable {
    let appID: UInt32
    let name: String
    var filename: String {
        var value = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: "\\", with: "-")
            .replacingOccurrences(of: ":", with: "-").trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        while value.utf8.count > 120 { value.removeLast() }
        if value.isEmpty { value = "Steam Game \(appID)" }
        if ["wineserver", "wine64", "wine-preloader", "wine64-preloader"].contains(value.lowercased()) { value += " Game" }
        return value
    }
}

/// A local, derived Wine application identity. The source runtime remains intact.
/// Wine derives child-loader paths from ntdll's real location, so linking only the
/// loader back to the source engine loses the application identity on re-exec.
struct SteamApplicationBundle: Sendable {
    let layout: RuntimeLayout
    let game: GameApplicationIdentity?
    init(layout: RuntimeLayout, game: GameApplicationIdentity? = nil) { self.layout = layout; self.game = game }
    static let identifier = "tech.endofline.gamekit.windows-steam"
    static let displayName = "Windows Steam"
    private var executableName: String { game?.filename ?? Self.displayName }
    private var driverCompatibility: Bool { layout.profile.revision == .driverVersion1 && game?.appID == 553850 }
    private let dxgiRelative = "Contents/SharedSupport/wine/lib/wine/x86_64-windows/dxgi.dll"
    private var bundleName: String { executableName + ".app" }
    private var parentURL: URL {
        if let game { layout.gameApplicationsRoot.appendingPathComponent("\(game.appID)/shared-pe-v2") }
        else { layout.launchersRoot }
    }
    var bundleURL: URL { parentURL.appendingPathComponent(bundleName) }
    var executable: URL { bundleURL.appendingPathComponent("Contents/MacOS/\(executableName)") }

    private struct Manifest: Codable, Equatable {
        let format: Int
        let runtime: RuntimeIdentity
        let hashes: [String: String]
    }
    private var expectedManifest: Manifest { .init(format: game == nil ? 1 : 2, runtime: layout.profile.identity, hashes: layout.profile.hashes) }
    private var info: [String: Any] {
        ["CFBundleIdentifier": game.map { "tech.endofline.gamekit.game.\($0.appID)" } ?? Self.identifier, "CFBundleExecutable": executableName,
         "CFBundleName": game?.name ?? Self.displayName, "CFBundleDisplayName": game?.name ?? Self.displayName,
         "CFBundlePackageType": "APPL", "CFBundleVersion": "1", "CFBundleShortVersionString": "1.0.0",
         "LSUIElement": true]
    }
    private func copiedPath(_ original: String) -> String? {
        let prefix = "Contents/SharedSupport/wine/"
        guard original.hasPrefix(prefix) else { return nil }
        let suffix = String(original.dropFirst(prefix.count))
        if suffix == "bin/wine" { return "Contents/MacOS/\(executableName)" }
        if suffix.hasPrefix("bin/") { return "Contents/MacOS/" + suffix.dropFirst(4) }
        return "Contents/" + suffix
    }
    func validate(_ bundle: URL, legacyGameCache: Bool = false) throws {
        let manifest = legacyGameCache ? Manifest(format: 1, runtime: layout.profile.identity, hashes: layout.profile.hashes) : expectedManifest
        guard let root = try ManagedDirectory.openRoot(bundle, create: false),
              let contents = try root.directory("Contents"),
              let manifestData = try contents.read("Gamekit-runtime.json"),
               try JSONDecoder().decode(Manifest.self, from: manifestData) == manifest,
              let plistData = try contents.read("Info.plist"),
              let plist = try PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any],
              NSDictionary(dictionary: plist).isEqual(to: info),
              try FileManager.default.destinationOfSymbolicLink(atPath: bundle.appendingPathComponent("Contents/bin").path) == "MacOS"
        else { throw SteamApplicationError.invalidBundle }
        for (path, hash) in layout.profile.hashes {
            guard let copy = copiedPath(path) else { continue }
            let expected = driverCompatibility && path == dxgiRelative ? layout.profile.hashes[RuntimeProfile.driverShimRelative] : hash
            guard let expected, RuntimeDetector.matches(bundle.appendingPathComponent(copy), root: bundle, hash: expected) else { throw SteamApplicationError.invalidBundle }
        }
        if game != nil && !legacyGameCache {
            guard let steam = try ManagedDirectory.openRoot(layout.steamApplicationBundle, create: false) else { throw SteamApplicationError.invalidBundle }
            for arch in ["x86_64-windows", "i386-windows"] {
                if let source = try steam.directory("Contents")?.directory("lib")?.directory("wine")?.directory(arch) {
                    guard let target = try contents.directory("lib")?.directory("wine")?.directory(arch) else { throw SteamApplicationError.invalidBundle }
                    try target.validateSharedFiles(from: source, privateRegularFiles: driverCompatibility && arch == "x86_64-windows" ? ["dxgi.dll"] : [])
                }
            }
        }
    }
    func prepare() async throws -> URL {
        if game != nil { _ = try await SteamApplicationBundle(layout: layout).prepare() }
        return try await Task.detached { try prepareSynchronously() }.value
    }
    private func prepareSynchronously() throws -> URL {
        guard RuntimeDetector.safeBundle(layout),
              let wineHash = layout.profile.hashes["Contents/SharedSupport/wine/bin/wine"],
              RuntimeDetector.matches(layout.wine, root: layout.bundle, hash: wineHash),
              let root = try ManagedDirectory.openRoot(layout.dataRoot, create: false),
              var launchers = try root.directory("Launchers", create: true)
        else { throw SteamApplicationError.invalidRuntime }
        if layout.profile.revision != .original {
            guard let directory = try launchers.directory("Revisions", create: true)?.directory(layout.profile.revision.rawValue, create: true)
            else { throw SteamApplicationError.invalidBundle }
            launchers = directory
        }
        if let game {
            guard game.appID > 0, !game.name.isEmpty, game.name.rangeOfCharacter(from: .controlCharacters) == nil,
                  let directory = try launchers.directory("Games", create: true)?.directory(String(game.appID), create: true)?.directory("shared-pe-v2", create: true)
            else { throw SteamApplicationError.invalidBundle }
            launchers = directory
        }
        let lock = try launchers.acquireLock(".windows-steam.lock")
        defer { withExtendedLifetime(lock) {} }
        if try launchers.directory(bundleName) != nil {
            try validate(bundleURL)
            return bundleURL
        }
        let stageName = ".windows-steam-" + UUID().uuidString.lowercased()
        let stage = try launchers.createExclusiveDirectory(stageName)
        let identity = try stage.identity()
        let stageURL = parentURL.appendingPathComponent(stageName)
        defer {
            // Only remove this attempt's staging directory, never an existing bundle.
            try? launchers.removeStagingDirectory(stageName, identity: identity)
        }
        let bundle = stageURL.appendingPathComponent(bundleName)
        let copied = try stage.createExclusiveDirectory(bundleName)
        let contents = try copied.createExclusiveDirectory("Contents")
        guard let source = try ManagedDirectory.openRoot(layout.engine, create: false) else { throw SteamApplicationError.invalidRuntime }
        try contents.copyContents(from: source)
        if game != nil {
            guard let steam = try ManagedDirectory.openRoot(layout.steamApplicationBundle, create: false) else { throw SteamApplicationError.invalidBundle }
            for arch in ["x86_64-windows", "i386-windows"] {
                if let images = try steam.directory("Contents")?.directory("lib")?.directory("wine")?.directory(arch) {
                    guard let target = try contents.directory("lib")?.directory("wine"), let old = try target.directory(arch) else { throw SteamApplicationError.invalidBundle }
                    try target.removeStagingDirectory(arch, identity: old.identity())
                    let shared = try target.createExclusiveDirectory(arch)
                    try shared.copyContents(from: images, shareRegularFiles: true)
                }
            }
        }
        if driverCompatibility {
            guard let shimHash = layout.profile.hashes[RuntimeProfile.driverShimRelative],
                  RuntimeDetector.matches(layout.bundle.appendingPathComponent(RuntimeProfile.driverShimRelative), root: layout.bundle, hash: shimHash),
                  let payload = try contents.directory("lib")?.directory("gamekit")?.read("helldivers-dxgi.dll"),
                  let modules = try contents.directory("lib")?.directory("wine")?.directory("x86_64-windows")
            else { throw SteamApplicationError.invalidRuntime }
            // Remove only the newly staged hard link, never overwrite its inode.
            try modules.removeRegularFile("dxgi.dll")
            try modules.write(payload, to: "dxgi.dll", createOnly: true, beforeCommit: {})
        }
        try contents.moveDirectory("bin", to: contents, as: "MacOS")
        guard let executables = try contents.directory("MacOS") else { throw SteamApplicationError.invalidBundle }
        if executableName != "wine" { try executables.renameRegularFile("wine", to: executableName) }
        try contents.createSymbolicLink("bin", target: "MacOS")
        try contents.write(PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0), to: "Info.plist", createOnly: true, beforeCommit: {})
        try contents.write(JSONEncoder().encode(expectedManifest), to: "Gamekit-runtime.json", createOnly: true, beforeCommit: {})
        try validate(bundle)
        guard let current = try launchers.directory(stageName), try current.identity() == identity else { throw EnvironmentStoreError.identityMismatch }
        try stage.moveDirectory(bundleName, to: launchers, as: bundleName)
        try validate(bundleURL)
        return bundleURL
    }

    static func launch(_ request: CommandRequest, layout: RuntimeLayout) async throws {
        let bundle = try await SteamApplicationBundle(layout: layout).prepare()
        try Task.checkCancellation()
        var arguments = ["-g", "-n", "-a", bundle.path, "--stdin", "/dev/null", "--stdout", "/dev/null", "--stderr", "/dev/null"]
        for (key, value) in request.environment.sorted(by: { $0.key < $1.key }) { arguments += ["--env", "\(key)=\(value)"] }
        arguments += ["--args"] + request.arguments
        let opened = try await ProcessExecutor().run(.init(executable: URL(fileURLWithPath: "/usr/bin/open"),
            arguments: arguments, timeout: 30, outputLimit: 8192, independentApplication: true))
        guard opened.termination == .exited(0) else { throw SteamApplicationError.invalidBundle }
    }
}
