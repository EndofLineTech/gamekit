import Foundation

public enum SteamApplicationError: Error, Equatable { case invalidBundle, invalidRuntime }

/// A local, derived Wine application identity. The source runtime remains intact.
/// Wine derives child-loader paths from ntdll's real location, so linking only the
/// loader back to the source engine loses the application identity on re-exec.
struct SteamApplicationBundle: Sendable {
    let layout: RuntimeLayout
    static let identifier = "tech.endofline.gamekit.windows-steam"
    static let displayName = "Windows Steam"

    private struct Manifest: Codable, Equatable {
        let format: Int
        let runtime: RuntimeIdentity
        let hashes: [String: String]
    }
    private var expectedManifest: Manifest { .init(format: 1, runtime: layout.profile.identity, hashes: layout.profile.hashes) }
    private var info: [String: Any] {
        ["CFBundleIdentifier": Self.identifier, "CFBundleExecutable": Self.displayName,
         "CFBundleName": Self.displayName, "CFBundleDisplayName": Self.displayName,
         "CFBundlePackageType": "APPL", "CFBundleVersion": "1", "CFBundleShortVersionString": "1.0.0",
         "LSUIElement": true]
    }
    private func copiedPath(_ original: String) -> String? {
        let prefix = "Contents/SharedSupport/wine/"
        guard original.hasPrefix(prefix) else { return nil }
        let suffix = String(original.dropFirst(prefix.count))
        if suffix == "bin/wine" { return "Contents/MacOS/Windows Steam" }
        if suffix.hasPrefix("bin/") { return "Contents/MacOS/" + suffix.dropFirst(4) }
        return "Contents/" + suffix
    }
    func validate(_ bundle: URL) throws {
        guard let root = try ManagedDirectory.openRoot(bundle, create: false),
              let contents = try root.directory("Contents"),
              let manifestData = try contents.read("Gamekit-runtime.json"),
              try JSONDecoder().decode(Manifest.self, from: manifestData) == expectedManifest,
              let plistData = try contents.read("Info.plist"),
              let plist = try PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any],
              NSDictionary(dictionary: plist).isEqual(to: info),
              try FileManager.default.destinationOfSymbolicLink(atPath: bundle.appendingPathComponent("Contents/bin").path) == "MacOS"
        else { throw SteamApplicationError.invalidBundle }
        for (path, hash) in layout.profile.hashes {
            guard let copy = copiedPath(path) else { continue }
            guard RuntimeDetector.matches(bundle.appendingPathComponent(copy), root: bundle, hash: hash) else { throw SteamApplicationError.invalidBundle }
        }
    }
    func prepare() async throws -> URL {
        try await Task.detached { try prepareSynchronously() }.value
    }
    private func prepareSynchronously() throws -> URL {
        guard RuntimeDetector.safeBundle(layout),
              let wineHash = layout.profile.hashes["Contents/SharedSupport/wine/bin/wine"],
              RuntimeDetector.matches(layout.wine, root: layout.bundle, hash: wineHash),
              let root = try ManagedDirectory.openRoot(layout.dataRoot, create: false),
              let launchers = try root.directory("Launchers", create: true)
        else { throw SteamApplicationError.invalidRuntime }
        let lock = try launchers.acquireLock(".windows-steam.lock")
        defer { withExtendedLifetime(lock) {} }
        if try launchers.directory("Windows Steam.app") != nil {
            try validate(layout.steamApplicationBundle)
            return layout.steamApplicationBundle
        }
        let stageName = ".windows-steam-" + UUID().uuidString.lowercased()
        let stage = try launchers.createExclusiveDirectory(stageName)
        let identity = try stage.identity()
        let stageURL = layout.dataRoot.appendingPathComponent("Launchers/\(stageName)")
        defer {
            // Only remove this attempt's staging directory, never an existing bundle.
            try? launchers.removeStagingDirectory(stageName, identity: identity)
        }
        let bundle = stageURL.appendingPathComponent("Windows Steam.app")
        let copied = try stage.createExclusiveDirectory("Windows Steam.app")
        let contents = try copied.createExclusiveDirectory("Contents")
        guard let source = try ManagedDirectory.openRoot(layout.engine, create: false) else { throw SteamApplicationError.invalidRuntime }
        try contents.copyContents(from: source)
        try contents.moveDirectory("bin", to: contents, as: "MacOS")
        guard let executables = try contents.directory("MacOS") else { throw SteamApplicationError.invalidBundle }
        try executables.renameRegularFile("wine", to: Self.displayName)
        try contents.createSymbolicLink("bin", target: "MacOS")
        try contents.write(PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0), to: "Info.plist", createOnly: true, beforeCommit: {})
        try contents.write(JSONEncoder().encode(expectedManifest), to: "Gamekit-runtime.json", createOnly: true, beforeCommit: {})
        try validate(bundle)
        guard let current = try launchers.directory(stageName), try current.identity() == identity else { throw EnvironmentStoreError.identityMismatch }
        try stage.moveDirectory("Windows Steam.app", to: launchers, as: "Windows Steam.app")
        try validate(layout.steamApplicationBundle)
        return layout.steamApplicationBundle
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
