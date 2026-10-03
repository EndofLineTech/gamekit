import CryptoKit
import Foundation

public enum RuntimeSetupError: Error, Equatable {
    case invalidRecipe, invalidAppleArtifact, invalidDownload, invalidArchive, invalidOverlay, alreadyInstalled
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
              (1...300_000_000).contains(engine.maximumBytes), (1...300_000_000).contains(template.maximumBytes),
              (1...100_000_000).contains(appleDMG.maximumBytes), appleDMG.url == nil,
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

    public func install(appleDMG: URL, onProgress: @escaping @Sendable (String) async -> Void = { _ in }) async throws -> URL {
        try Task.checkCancellation()
        guard !appleDMG.isSymlink, appleDMG.isFileURL,
              try Self.digest(appleDMG, maximumBytes: recipe.appleDMG.maximumBytes) == recipe.appleDMG.sha256
        else { throw RuntimeSetupError.invalidAppleArtifact }
        let path = recipe.runtimeBundlePath.split(separator: "/").map(String.init)
        guard path.count == 3, path[0] == "Runtimes" else { throw RuntimeSetupError.invalidRecipe }
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
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("Gamekit runtime setup " + UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: temporary) }

        await onProgress("Downloading verified Wine engine from its publisher…")
        let engine = try await verifiedDownload(recipe.engine, to: temporary.appendingPathComponent("engine.tar.xz"))
        await onProgress("Downloading verified runtime template from its publisher…")
        let template = try await verifiedDownload(recipe.template, to: temporary.appendingPathComponent("template.tar.xz"))
        try Task.checkCancellation()
        await onProgress("Extracting the pinned runtime into a private staging area…")
        try await unpack(template, to: stageURL)
        let engineRoot = temporary.appendingPathComponent("engine")
        try FileManager.default.createDirectory(at: engineRoot, withIntermediateDirectories: false)
        try await unpack(engine, to: engineRoot)
        let app = stageURL.appendingPathComponent(path[2])
        let sourceWine = engineRoot.appendingPathComponent("wswine.bundle")
        let destination = app.appendingPathComponent("Contents/SharedSupport/wine")
        guard !sourceWine.isSymlink, sourceWine.isDirectory, !destination.exists else { throw RuntimeSetupError.invalidArchive }
        try FileManager.default.moveItem(at: sourceWine, to: destination)
        try Task.checkCancellation()

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

    private struct Receipt: Codable {
        let schemaVersion: Int
        let engineSHA256: String
        let templateSHA256: String
        let appleDMGSHA256: String
        let createdAt: Date
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
