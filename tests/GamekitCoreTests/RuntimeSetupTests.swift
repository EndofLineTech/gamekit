import Foundation
import Testing
@testable import GamekitCore

@Suite("User-supplied runtime setup")
struct RuntimeSetupTests {
    @Test("Publisher download returns the exact pinned archive without saving credentials",
          .enabled(if: ProcessInfo.processInfo.environment["GAMEKIT_RUNTIME_DOWNLOAD_SMOKE"] == "1"))
    func publisherDownload() async throws {
        let recipe = try RuntimeSetupRecipe.bundled()
        for artifact in [recipe.engine, recipe.template] {
            let downloaded = try await RuntimeArchiveDownload.fetch(artifact)
            defer { try? FileManager.default.removeItem(at: downloaded) }
            #expect(try RuntimeSetup.digest(downloaded, maximumBytes: artifact.maximumBytes) == artifact.sha256)
        }
    }
    @Test("Verified user-owned source archives assemble into a separate runtime without touching originals",
          .enabled(if: ProcessInfo.processInfo.environment["GAMEKIT_RUNTIME_SETUP_SMOKE"] == "1"))
    func realArtifactComposition() async throws {
        let environment = ProcessInfo.processInfo.environment
        let engine = try #require(environment["GAMEKIT_RUNTIME_ENGINE_ARCHIVE"]).fileURL
        let template = try #require(environment["GAMEKIT_RUNTIME_TEMPLATE_ARCHIVE"]).fileURL
        let apple = try #require(environment["GAMEKIT_RUNTIME_APPLE_DMG"]).fileURL
        let recipe = try RuntimeSetupRecipe.bundled()
        func sourceHashes() throws -> [String] {
            try [engine, template, apple].map { path in
                guard let hash = try RuntimeSetup.digest(path, maximumBytes: 300_000_000) else {
                    throw RuntimeSetupError.invalidAppleArtifact
                }
                return hash
            }
        }
        let originalHashes = try sourceHashes()
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("Gamekit runtime composition " + UUID().uuidString)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        let downloads = parent.appendingPathComponent("downloads")
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: false)
        let setup = try RuntimeSetup(root: parent.appendingPathComponent("Gamekit"), recipe: recipe, transfer: { artifact in
            let original = artifact.sha256 == recipe.engine.sha256 ? engine : template
            let copy = downloads.appendingPathComponent(UUID().uuidString + ".tar.xz")
            try FileManager.default.copyItem(at: original, to: copy)
            return copy
        })
        #expect(try await !setup.hasPreparedWine())
        let prepared = try await setup.prepareWine()
        #expect(try await setup.hasPreparedWine())
        let wineReport = try await RuntimeDetector().detect(
            RuntimeLayout(dataRoot: parent.appendingPathComponent("Gamekit"), bundle: prepared),
            selection: RuntimeProfile.sikarugir.identity)
        #expect(wineReport.checks.first(where: { $0.prerequisite == .runtime })?.status == .passed)
        #expect(wineReport.checks.first(where: { $0.prerequisite == .graphicsPayload })?.status == .failed)
        #expect(try await setup.prepareWine() == prepared)
        let resumed = try RuntimeSetup(root: parent.appendingPathComponent("Gamekit"), recipe: recipe, transfer: { _ in
            throw RuntimeSetupError.invalidDownload
        })
        #expect(try await resumed.hasPreparedWine())
        let result = try await resumed.install(appleDMG: apple)
        #expect(result.resolvingSymlinksInPath() == parent.appendingPathComponent("Gamekit/" + recipe.runtimeBundlePath).resolvingSymlinksInPath())
        let layout = RuntimeLayout(dataRoot: parent.appendingPathComponent("Gamekit"), bundle: result)
        #expect(try await RuntimeDetector().detect(layout, selection: layout.profile.identity).prerequisites == .ready)
        #expect(try sourceHashes() == originalHashes)
        #expect(try FileManager.default.contentsOfDirectory(atPath: downloads.path).isEmpty)
        await #expect(throws: RuntimeSetupError.alreadyInstalled) { try await resumed.install(appleDMG: apple) }
    }
    @Test("Bundled sources are exact HTTPS downloads and the selected runtime has one destination")
    func sourceRecipe() throws {
        let recipe = try RuntimeSetupRecipe.bundled()
        #expect(recipe.runtimeBundlePath == RuntimeProfile.sikarugir.bundlePath)
        #expect(recipe.engine.url?.scheme == "https")
        #expect(recipe.template.url?.scheme == "https")
        #expect(recipe.engine.url?.host == "github.com" && recipe.template.url?.host == "github.com")
        #expect(recipe.engine.sha256.count == 64 && recipe.template.sha256.count == 64 && recipe.appleDMG.sha256.count == 64)
    }

    @Test("Changed or redirected user-supplied Apple files fail before any runtime publication")
    func invalidAppleArtifact() async throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        let artifact = parent.appendingPathComponent("Apple.dmg")
        try Data("not the selected Apple image".utf8).write(to: artifact)
        let root = parent.appendingPathComponent("Gamekit")
        let setup = try RuntimeSetup(root: root)
        await #expect(throws: RuntimeSetupError.invalidAppleArtifact) { try await setup.install(appleDMG: artifact) }
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(RuntimeProfile.sikarugir.bundlePath).path))
        try FileManager.default.removeItem(at: artifact)
        try FileManager.default.createSymbolicLink(at: artifact, withDestinationURL: parent.appendingPathComponent("outside.dmg"))
        await #expect(throws: RuntimeSetupError.invalidAppleArtifact) { try await setup.install(appleDMG: artifact) }
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("Runtimes").path))
    }

    @Test("A mismatched publisher download is discarded and cannot publish a partial runtime")
    func invalidPublisherDownload() async throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        let apple = parent.appendingPathComponent("Apple.dmg")
        try Data("test image".utf8).write(to: apple)
        let source = parent.appendingPathComponent("download.tar.xz")
        let bundled = try RuntimeSetupRecipe.bundled()
        let appleHash = try RuntimeSetup.digest(apple, maximumBytes: 100)
        let recipe = RuntimeSetupRecipe(schemaVersion: bundled.schemaVersion, runtimeBundlePath: bundled.runtimeBundlePath,
            engine: bundled.engine, template: bundled.template,
            appleDMG: .init(url: nil, sha256: try #require(appleHash), maximumBytes: 100),
            applePackageDMG: bundled.applePackageDMG, evaluationImageName: bundled.evaluationImageName)
        let root = parent.appendingPathComponent("Gamekit")
        let setup = try RuntimeSetup(root: root, recipe: recipe, transfer: { _ in
            try Data("wrong archive".utf8).write(to: source)
            return source
        })
        await #expect(throws: RuntimeSetupError.invalidDownload) { try await setup.install(appleDMG: apple) }
        #expect(!FileManager.default.fileExists(atPath: source.path))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(bundled.runtimeBundlePath).path))
        let contents = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("Runtimes").path)
        #expect(!contents.contains(where: { $0.hasPrefix(".runtime-setup-") }))
    }
}

private extension String {
    var fileURL: URL { URL(fileURLWithPath: self) }
}
