import Foundation
import CryptoKit
import Darwin
import Testing
@testable import GamekitCore

@Suite("Opt-in Satisfactory protected-save observation")
struct SatisfactoryPerformanceTests {
    @Test("Observe alternate configuration with protected saves and restore the backend",
          .enabled(if: ProcessInfo.processInfo.environment["GAMEKIT_SATISFACTORY_PERFORMANCE"] == "1"))
    func observe() async throws {
        let env = ProcessInfo.processInfo.environment
        try #require(env["GAMEKIT_E6_APPID"] == "526870" && env["GAMEKIT_E6_SATISFACTORY_D3D11"] == "1")
        let backend = try #require(env["GAMEKIT_PROBE_BACKEND"].flatMap(GameGraphicsOverride.init(rawValue:)))
        try #require([.dxvk, .dxmt].contains(backend))
        let sandbox = URL(fileURLWithPath: try #require(env["GAMEKIT_E6_SATISFACTORY_USER_DIR"]))
        let store = try EnvironmentStore()
        let layout = try await RuntimeSettingsStore(store: store).layout()
        let lifecycle = SteamLifecycle(store: store, layout: layout)
        let record = try #require(await store.load(SteamInstallationRecipe.environmentID))
        let prefix = store.prefixURL(for: record.id)
        let initial = await RuntimeProcessObserver().inspect(record: record, prefix: prefix, layout: layout)
        try #require(initial.complete && !initial.processes.contains { $0.role == .other })
        _ = try await lifecycle.stop()
        let settings = GameCompatibilityStore(store: store)
        let original = try await settings.inspectGraphics(appID: 526870)
        let sourceURL = URL(fileURLWithPath: try #require(env["GAMEKIT_SATISFACTORY_SAVED"]))
        try #require(sourceURL.path.hasPrefix(prefix.path + "/drive_c/users/") && sourceURL.lastPathComponent == "Saved")
        let source = try #require(try ManagedDirectory.openRoot(sourceURL, create: false))
        func snapshot(_ directory: ManagedDirectory, depth: Int = 0) throws -> [String: Data] {
            try #require(depth < 8)
            var result: [String: Data] = [:]
            for name in try directory.names() {
                var info = stat()
                try #require(fstatat(directory.descriptor, name, &info, AT_SYMLINK_NOFOLLOW) == 0)
                if info.st_mode & S_IFMT == S_IFDIR {
                    let child = try #require(try directory.directory(name))
                    for (path, bytes) in try snapshot(child, depth: depth + 1) { result[name + "/" + path] = bytes }
                } else {
                    try #require(info.st_mode & S_IFMT == S_IFREG)
                    let data = try #require(try directory.read(name, maximumBytes: 64 * 1024 * 1024))
                    result[name] = Data(SHA256.hash(data: data))
                }
            }
            return result
        }
        let saves = try #require(try source.directory("SaveGames"))
        try #require(env["GAMEKIT_E6_SANDBOX_CONTINUE"] != "1" || env["GAMEKIT_SAVE_GUARD_HELPER"] == "1", "Supply the save-guard diagnostic helper for world observations")
        if env["GAMEKIT_E6_SANDBOX_CONTINUE"] == "1" {
            let package = URL(fileURLWithPath: try #require(env["GAMEKIT_E6_PACKAGE"]))
            let helper = try Data(contentsOf: package.appendingPathComponent("Contents/Frameworks/WineGameIdentity.dylib"))
            try #require(helper.range(of: Data("Gamekit diagnostic save-write guard verified".utf8)) != nil)
            try #require(helper.range(of: Data(sourceURL.appendingPathComponent("SaveGames").path.utf8)) != nil)
            let logPath = try #require(env["GAMEKIT_SAVE_GUARD_LOG_FILE"])
            try #require(helper.range(of: Data(logPath.utf8)) != nil)
        }
        let before = try snapshot(saves)
        let config = try #require(try source.directory("Config")?.directory("Windows"))
        let configBefore = try snapshot(config)
        let parent = try #require(try ManagedDirectory.openRoot(sandbox.deletingLastPathComponent(), create: false))
        let isolated = try parent.createExclusiveDirectory(sandbox.lastPathComponent)
        let sandboxConfig = try isolated.directory("Saved", create: true)?.directory("Config", create: true)?.directory("Windows", create: true)
        try #require(sandboxConfig != nil)
        for name in configBefore.keys {
            try #require(!name.contains("/"))
            let bytes = try #require(try config.read(name))
            try sandboxConfig?.write(bytes, to: name, createOnly: true, beforeCommit: {})
        }
        func cleanup() async throws {
            _ = try await lifecycle.stop()
            _ = try await settings.setGraphicsBackend(original.override, appID: 526870)
            #expect(try snapshot(saves) == before, "Original saves must remain byte-identical")
            #expect(try snapshot(config) == configBefore, "Original config must remain byte-identical")
            print("Original save/config byte comparison completed; backend restored")
        }
        do {
            _ = try await settings.setGraphicsBackend(backend, appID: 526870)
            try await GameEvaluationLaunchTests().observeLaunch()
            try await cleanup()
        } catch {
            try await cleanup()
            throw error
        }
        let logs = try #require(try isolated.directory("Saved")?.directory("Logs"))
        let gameLog = try #require(try logs.read("FactoryGame.log", maximumBytes: 16 * 1024 * 1024))
        if env["GAMEKIT_E6_SANDBOX_CONTINUE"] == "1" {
            #expect(String(decoding: gameLog, as: UTF8.self).contains("LoadMap(/Game/FactoryGame/Map/GameLevel01/Persistent_Level)"), "World load must complete; opening the Load menu is insufficient")
        }
    }
}
