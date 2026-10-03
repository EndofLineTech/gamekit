import CryptoKit
import Foundation

public enum RuntimeSetupError: Error, Equatable {
    case invalidRecipe, invalidAppleArtifact, invalidDownload, invalidArchive, invalidOverlay, invalidPreparedWine, alreadyInstalled
}

public struct RuntimeSetupRecipe: Codable, Sendable {
    public struct Artifact: Codable, Sendable {
        public let url: URL?
        public let sha256: String
        public let maximumBytes: Int
    }
    public let schemaVersion: Int
    public let runtimeBundlePath: String
    public let engine: Artifact
    public let template: Artifact
    public let appleDMG: Artifact
    public let applePackageDMG: Artifact
    public let evaluationImageName: String

    public static func bundled() throws -> Self {
        guard let url = Bundle.module.url(forResource: "sikarugir-10.0_6", withExtension: "json", subdirectory: "RuntimeProfiles"),
              let recipe = try? JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        else { throw RuntimeSetupError.invalidRecipe }
        try recipe.validate()
        return recipe
    }

    func validate() throws {
        func validHash(_ value: String) -> Bool {
            value.count == 64 && value.allSatisfy { "0123456789abcdef".contains($0) }
        }
        func validProvider(_ url: URL?) -> Bool {
            guard let url else { return false }
            return url.scheme == "https" && url.host == "github.com" && url.user == nil &&
                url.password == nil && url.query == nil && url.fragment == nil &&
                url.path.hasSuffix(".tar.xz") && url.path.contains("/releases/download/")
        }
        guard schemaVersion == 1, runtimeBundlePath == RuntimeProfile.sikarugir.bundlePath,
               validHash(engine.sha256), validHash(template.sha256), validHash(appleDMG.sha256),
               validHash(applePackageDMG.sha256),
               (1...300_000_000).contains(engine.maximumBytes), (1...300_000_000).contains(template.maximumBytes),
               (1...100_000_000).contains(appleDMG.maximumBytes), appleDMG.url == nil,
               (1...200_000_000).contains(applePackageDMG.maximumBytes), applePackageDMG.url == nil,
               !evaluationImageName.isEmpty, evaluationImageName != ".", evaluationImageName != "..",
               !evaluationImageName.contains("/"), !evaluationImageName.utf8.contains(0),
              validProvider(engine.url), validProvider(template.url)
        else { throw RuntimeSetupError.invalidRecipe }
    }
}

/// A user-initiated side-by-side composition of verified external artifacts.
/// The user's existing runtimes, selection and Wine prefixes are never replaced.
public actor RuntimeSetup {
    public nonisolated let root: URL
    private let recipe: RuntimeSetupRecipe
    private let transfer: @Sendable (RuntimeSetupRecipe.Artifact) async throws -> URL

    public init(root: URL = EnvironmentStore.applicationSupportRoot) throws {
        self.root = try ManagedDirectory.canonicalRoot(root)
        recipe = try RuntimeSetupRecipe.bundled()
        transfer = { try await RuntimeArchiveDownload.fetch($0) }
    }

    init(root: URL, recipe: RuntimeSetupRecipe, transfer: @escaping @Sendable (RuntimeSetupRecipe.Artifact) async throws -> URL) throws {
        try recipe.validate()
        self.root = try ManagedDirectory.canonicalRoot(root)
        self.recipe = recipe
        self.transfer = transfer
    }

    /// Wine is prepared independently of Apple's graphics. It is not selected or
    /// executable through a managed launcher until the complete runtime is ready.
    public func prepareWine(onProgress: @escaping @Sendable (String) async -> Void = { _ in }) async throws -> URL {
        try Task.checkCancellation()
        let path = try bundleComponents()
        let store = try EnvironmentStore(root: root)
        guard let base = try ManagedDirectory.openRoot(store.root, create: true),
              let runtimes = try base.directory("Runtimes", create: true)
        else { throw RuntimeSetupError.invalidRecipe }
        let lock = try runtimes.acquireLock(".runtime-setup.lock")
        defer { withExtendedLifetime(lock) {} }
        guard try runtimes.directory(path[1]) == nil else { throw RuntimeSetupError.alreadyInstalled }
        let preparedName = ".prepared-" + path[1]
        if let prepared = try runtimes.directory(preparedName) {
            try await verifyPrepared(prepared, name: preparedName, appName: path[2])
            return root.appendingPathComponent("Runtimes/\(preparedName)/\(path[2])")
        }
        let stageName = ".runtime-setup-" + UUID().uuidString.lowercased()
        let stage = try runtimes.createExclusiveDirectory(stageName)
        let identity = try stage.identity()
        let stageURL = root.appendingPathComponent("Runtimes/" + stageName)
        defer { try? runtimes.removeStagingDirectory(stageName, identity: identity) }
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("Gamekit runtime setup " + UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: temporary) }

        await onProgress("Downloading verified Wine engine from its publisher…")
        let engine = try await verifiedDownload(recipe.engine, to: temporary.appendingPathComponent("engine.tar.xz"))
        await onProgress("Downloading verified runtime template from its publisher…")
        let template = try await verifiedDownload(recipe.template, to: temporary.appendingPathComponent("template.tar.xz"))
        try Task.checkCancellation()
        await onProgress("Extracting and verifying Wine in a private staging area…")
        try await unpack(template, to: stageURL)
        let engineRoot = temporary.appendingPathComponent("engine")
        try FileManager.default.createDirectory(at: engineRoot, withIntermediateDirectories: false)
        try await unpack(engine, to: engineRoot)
        let app = stageURL.appendingPathComponent(path[2])
        let sourceWine = engineRoot.appendingPathComponent("wswine.bundle")
        let destination = app.appendingPathComponent("Contents/SharedSupport/wine")
        guard !sourceWine.isSymlink, sourceWine.isDirectory, !destination.exists else { throw RuntimeSetupError.invalidArchive }
        try FileManager.default.moveItem(at: sourceWine, to: destination)
        try await verifyWine(app)
        let receipt = try JSONEncoder().encode(WineReceipt(schemaVersion: 1, engineSHA256: recipe.engine.sha256,
            templateSHA256: recipe.template.sha256))
        try stage.write(receipt, to: "wine-preparation.json", createOnly: true, beforeCommit: {})
        try Task.checkCancellation()
        try runtimes.moveDirectory(stageName, to: runtimes, as: preparedName)
        await onProgress("Wine is prepared. Choose the Apple DMG to finish graphics setup.")
        return root.appendingPathComponent("Runtimes/\(preparedName)/\(path[2])")
    }

    public func hasPreparedWine() async throws -> Bool {
        let path = try bundleComponents()
        guard let rootDirectory = try ManagedDirectory.openRoot(root, create: false),
              let runtimes = try rootDirectory.directory("Runtimes"),
              let prepared = try runtimes.directory(".prepared-" + path[1]) else { return false }
        try await verifyPrepared(prepared, name: ".prepared-" + path[1], appName: path[2])
        return true
    }

    public func install(appleDMG: URL, onProgress: @escaping @Sendable (String) async -> Void = { _ in }) async throws -> URL {
        try Task.checkCancellation()
        return try await withVerifiedAppleImage(appleDMG) { verifiedImage in
            try await installVerified(appleDMG: verifiedImage, onProgress: onProgress)
        }
    }

    private func installVerified(appleDMG: URL, onProgress: @escaping @Sendable (String) async -> Void) async throws -> URL {
        let path = try bundleComponents()
        _ = try await prepareWine(onProgress: onProgress)
        let store = try EnvironmentStore(root: root)
        guard let base = try ManagedDirectory.openRoot(store.root, create: true),
              let runtimes = try base.directory("Runtimes", create: true)
        else { throw RuntimeSetupError.invalidRecipe }
        let lock = try runtimes.acquireLock(".runtime-setup.lock")
        defer { withExtendedLifetime(lock) {} }
        guard try runtimes.directory(path[1]) == nil else { throw RuntimeSetupError.alreadyInstalled }
        let stageName = ".runtime-setup-" + UUID().uuidString.lowercased()
        let stage = try runtimes.createExclusiveDirectory(stageName)
        let identity = try stage.identity()
        let stageURL = root.appendingPathComponent("Runtimes/" + stageName)
        defer { try? runtimes.removeStagingDirectory(stageName, identity: identity) }
        let preparedName = ".prepared-" + path[1]
        guard let prepared = try runtimes.directory(preparedName),
              let preparedApp = try prepared.directory(path[2]) else { throw RuntimeSetupError.invalidPreparedWine }
        try await verifyPrepared(prepared, name: preparedName, appName: path[2])
        try Task.checkCancellation()
        await onProgress("Copying verified Wine into a private graphics staging area…")
        let copy = try stage.createExclusiveDirectory(path[2])
        try copy.copyContents(from: preparedApp)
        let app = stageURL.appendingPathComponent(path[2])
        try await verifyWine(app)
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("Gamekit graphics setup " + UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: temporary) }

        await onProgress("Verifying and assembling your Apple Game Porting Toolkit graphics…")
        try await overlayApple(appleDMG, into: app, temporary: temporary)
        let layout = RuntimeLayout(dataRoot: root, profile: .sikarugir, bundle: app)
        let report = try await RuntimeDetector().detect(layout, selection: layout.profile.identity)
        guard report.prerequisites == .ready else { throw RuntimeSetupError.invalidOverlay }
        let receipt = try JSONEncoder().encode(Receipt(schemaVersion: 1, engineSHA256: recipe.engine.sha256,
            templateSHA256: recipe.template.sha256, appleDMGSHA256: recipe.appleDMG.sha256, createdAt: Date()))
        try stage.write(receipt, to: "runtime-setup.json", createOnly: true, beforeCommit: {})
        try Task.checkCancellation()
        guard try runtimes.directory(path[1]) == nil else { throw RuntimeSetupError.alreadyInstalled }
        try runtimes.moveDirectory(stageName, to: runtimes, as: path[1])
        await onProgress("Runtime is ready. You can now install Steam.")
        return root.appendingPathComponent(recipe.runtimeBundlePath)
    }

    private func withVerifiedAppleImage<T>(_ supplied: URL, operation: (URL) async throws -> T) async throws -> T {
        guard supplied.isFileURL, !supplied.isSymlink else { throw RuntimeSetupError.invalidAppleArtifact }
        if try Self.digest(supplied, maximumBytes: recipe.appleDMG.maximumBytes) == recipe.appleDMG.sha256 {
            return try await operation(supplied)
        }
        guard try Self.digest(supplied, maximumBytes: recipe.applePackageDMG.maximumBytes) == recipe.applePackageDMG.sha256
        else { throw RuntimeSetupError.invalidAppleArtifact }
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("Gamekit Apple image " + UUID().uuidString)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: parent) }
        let mount = parent.appendingPathComponent("outer-mount")
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: false)
        let attach = try await ProcessExecutor().run(.init(executable: URL(fileURLWithPath: "/usr/bin/hdiutil"),
            arguments: ["attach", "-readonly", "-nobrowse", "-noautoopen", "-mountpoint", mount.path, supplied.path],
            timeout: 45, outputLimit: 4096))
        guard attach.termination == .exited(0) else { throw RuntimeSetupError.invalidAppleArtifact }
        do {
            let image = mount.appendingPathComponent(recipe.evaluationImageName)
            guard try Self.digest(image, maximumBytes: recipe.appleDMG.maximumBytes) == recipe.appleDMG.sha256
            else { throw RuntimeSetupError.invalidAppleArtifact }
            let result = try await operation(image)
            try await Task.detached { try await Self.detach(mount) }.value
            return result
        } catch {
            try? await Task.detached { try await Self.detach(mount) }.value
            throw error
        }
    }

    private struct Receipt: Codable {
        let schemaVersion: Int
        let engineSHA256: String
        let templateSHA256: String
        let appleDMGSHA256: String
        let createdAt: Date
    }

    private struct WineReceipt: Codable {
        let schemaVersion: Int
        let engineSHA256: String
        let templateSHA256: String
    }

    private func bundleComponents() throws -> [String] {
        let path = recipe.runtimeBundlePath.split(separator: "/").map(String.init)
        guard path.count == 3, path[0] == "Runtimes" else { throw RuntimeSetupError.invalidRecipe }
        return path
    }

    private func verifyPrepared(_ prepared: ManagedDirectory, name: String, appName: String) async throws {
        guard let bytes = try prepared.read("wine-preparation.json", maximumBytes: 4096),
              let receipt = try? JSONDecoder().decode(WineReceipt.self, from: bytes),
              receipt.schemaVersion == 1, receipt.engineSHA256 == recipe.engine.sha256,
              receipt.templateSHA256 == recipe.template.sha256,
              try prepared.directory(appName) != nil else { throw RuntimeSetupError.invalidPreparedWine }
        try await verifyWine(root.appendingPathComponent("Runtimes/\(name)/\(appName)"))
    }

    private func verifyWine(_ app: URL) async throws {
        let layout = RuntimeLayout(dataRoot: root, profile: .sikarugir, bundle: app)
        let report = try await RuntimeDetector().detect(layout, selection: layout.profile.identity)
        guard report.checks.first(where: { $0.prerequisite == .runtime })?.status != .failed,
              report.checks.first(where: { $0.prerequisite == .graphicsPayload })?.status == .failed
        else { throw RuntimeSetupError.invalidPreparedWine }
    }

    private func verifiedDownload(_ artifact: RuntimeSetupRecipe.Artifact, to destination: URL) async throws -> URL {
        let downloaded = try await transfer(artifact)
        defer { try? FileManager.default.removeItem(at: downloaded) }
        guard try Self.digest(downloaded, maximumBytes: artifact.maximumBytes) == artifact.sha256 else {
            throw RuntimeSetupError.invalidDownload
        }
        try FileManager.default.moveItem(at: downloaded, to: destination)
        return destination
    }

    private func unpack(_ archive: URL, to destination: URL) async throws {
        let result = try await ProcessExecutor().run(.init(executable: URL(fileURLWithPath: "/usr/bin/tar"),
            arguments: ["-xJf", archive.path, "-C", destination.path, "--no-same-owner", "--no-same-permissions"],
            timeout: 180, outputLimit: 4096, outputMode: .discard))
        guard result.termination == .exited(0) else { throw RuntimeSetupError.invalidArchive }
    }

    private func overlayApple(_ image: URL, into app: URL, temporary: URL) async throws {
        let mount = temporary.appendingPathComponent("apple-mount")
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: false)
        let attach = try await ProcessExecutor().run(.init(executable: URL(fileURLWithPath: "/usr/bin/hdiutil"),
            arguments: ["attach", "-readonly", "-nobrowse", "-noautoopen", "-mountpoint", mount.path, image.path],
            timeout: 45, outputLimit: 4096))
        guard attach.termination == .exited(0) else { throw RuntimeSetupError.invalidAppleArtifact }
        do {
            let lib = mount.appendingPathComponent("redist/lib")
            let framework = lib.appendingPathComponent("external/D3DMetal.framework")
            guard !lib.isSymlink, lib.isDirectory,
                  try Self.digest(framework.appendingPathComponent("Versions/A/D3DMetal"), maximumBytes: 64 * 1024 * 1024) ==
                    RuntimeProfile.sikarugir.hashes["Contents/SharedSupport/wine/lib/external/D3DMetal.framework/Versions/A/D3DMetal"]
            else { throw RuntimeSetupError.invalidAppleArtifact }
            let signature = try await ProcessExecutor().run(.init(executable: URL(fileURLWithPath: "/usr/bin/codesign"),
                arguments: ["--verify", "--deep", "--strict", framework.path], timeout: 30, outputLimit: 4096))
            guard signature.termination == .exited(0) else { throw RuntimeSetupError.invalidAppleArtifact }
            let target = app.appendingPathComponent("Contents/SharedSupport/wine/lib")
            let copy = try await ProcessExecutor().run(.init(executable: URL(fileURLWithPath: "/usr/bin/ditto"),
                arguments: [lib.path, target.path], timeout: 90, outputLimit: 4096))
            guard copy.termination == .exited(0) else { throw RuntimeSetupError.invalidOverlay }
            try await Task.detached { try await Self.detach(mount) }.value
        } catch {
            // A cancelled installation must still unmount its user-selected image.
            try? await Task.detached { try await Self.detach(mount) }.value
            throw error
        }
    }

    private nonisolated static func detach(_ mount: URL) async throws {
        let result = try await ProcessExecutor().run(.init(executable: URL(fileURLWithPath: "/usr/bin/hdiutil"),
            arguments: ["detach", mount.path], timeout: 30, outputLimit: 4096))
        guard result.termination == .exited(0) else { throw RuntimeSetupError.invalidAppleArtifact }
    }

    static func digest(_ file: URL, maximumBytes: Int) throws -> String? {
        guard file.isFileURL, !file.isSymlink,
              let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true, let size = values.fileSize,
              size > 0, size <= maximumBytes,
              let handle = try? FileHandle(forReadingFrom: file)
        else { return nil }
        defer { try? handle.close() }
        var hash = SHA256()
        while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            hash.update(data: chunk)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

private extension URL {
    var isSymlink: Bool { (try? resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true }
    var isDirectory: Bool { (try? resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
    var exists: Bool { FileManager.default.fileExists(atPath: path) }
}
