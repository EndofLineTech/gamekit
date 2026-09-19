import Foundation
import Testing
@testable import GamekitCore

@Suite("Opt-in per-game backend acceptance")
struct PerGameBackendAcceptanceTests {
    @Test("Explicitly set and read back a stopped game's backend for live acceptance",
          .enabled(if: ProcessInfo.processInfo.environment["GAMEKIT_BACKEND_SETTING"] != nil))
    func liveSetting() async throws {
        let env = ProcessInfo.processInfo.environment
        let appID = try #require(env["GAMEKIT_BACKEND_APPID"].flatMap(UInt32.init))
        let choice = try #require(env["GAMEKIT_BACKEND_SETTING"].flatMap(GameGraphicsOverride.init(rawValue:)))
        let store = try EnvironmentStore()
        if let raw = env["GAMEKIT_SHARED_BACKEND_SETTING"] {
            try await RuntimeSettingsStore(store: store).selectGraphicsBackend(try #require(D3DMetalBackend(rawValue: raw)))
        }
        let saved = try await GameCompatibilityStore(store: store).setGraphicsBackend(choice, appID: appID)
        #expect(saved.override == choice)
        print("Backend appID=\(appID) override=\(saved.override.rawValue) shared=\(saved.sharedBackend.rawValue) effective=\(saved.effectiveBackend.rawValue)")
    }
    @Test("Real Wine processes receive independent game overrides and shared defaults",
          .enabled(if: ProcessInfo.processInfo.environment["GAMEKIT_PER_GAME_BACKEND_ACCEPTANCE"] == "1"))
    func isolatedBackends() async throws {
        let env = ProcessInfo.processInfo.environment
        let probe = URL(fileURLWithPath: try #require(env["GAMEKIT_BACKEND_PROBE_PATH"]))
        let helper = URL(fileURLWithPath: try #require(env["GAMEKIT_IDENTITY_X86_HELPER"]))
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("Gamekit Backend " + UUID().uuidString)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let store = try EnvironmentStore(root: parent.appendingPathComponent("Gamekit"))
        let selected = try await RuntimeSettingsStore(store: EnvironmentStore()).layout()
        let settings = RuntimeSettingsStore(store: store)
        let id = SteamInstallationRecipe.environmentID
        _ = try await store.create(.init(id: id, name: "Backend probe", runtime: selected.profile.identity, installation: .installed, installationRecipeVersion: 1))
        let prefix = store.prefixURL(for: id)
        try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: true)
        try await settings.select(selected.bundle, revision: selected.profile.revision, graphicsBackend: .metal3)
        func layout() async throws -> RuntimeLayout {
            let saved = try await settings.layout()
            return RuntimeLayout(dataRoot: store.root, profile: saved.profile, bundle: saved.bundle, identityHelper: helper, graphicsBackend: saved.graphicsBackend)
        }
        let initialization = try await RuntimeSession.start(store: store, id: id, layout: layout(), arguments: SteamInstallationRecipe.initializeArguments, timeout: 120)
        let boot = await initialization.command.result()
        _ = try await initialization.stop()
        try #require(boot.termination == .exited(0))
        let steam = prefix.appendingPathComponent(RelativePath.steamDefault.rawValue).deletingLastPathComponent()
        let apps = steam.appendingPathComponent("steamapps")
        for (appID, title) in [(UInt32(900001), "Probe A"), (900002, "Probe B")] {
            let directory = apps.appendingPathComponent("common/\(title)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: probe, to: directory.appendingPathComponent("probe.exe"))
            try Data("\"AppState\" { \"appid\" \"\(appID)\" \"name\" \"\(title)\" \"installdir\" \"\(title)\" \"StateFlags\" \"4\" }".utf8).write(to: apps.appendingPathComponent("appmanifest_\(appID).acf"))
        }
        try Data("probe fixture, never executed".utf8).write(to: steam.appendingPathComponent("Steam.exe"))
        let gameSettings = GameCompatibilityStore(store: store)
        func run(_ appID: UInt32?, _ expected: String) async throws {
            let session: RuntimeSession
            if let appID {
                let title = appID == 900001 ? "Probe A" : "Probe B"
                session = try await RuntimeSession.startGameProbe(store: store, id: id, layout: layout(),
                    game: .init(appID: appID, name: title), arguments: [apps.appendingPathComponent("common/\(title)/probe.exe").path, expected])
            } else {
                session = try await RuntimeSession.start(store: store, id: id, layout: layout(), arguments: [probe.path, expected], timeout: 60)
            }
            let result = await session.command.result()
            print("Backend appID=\(appID ?? 0): \(result.stdoutText)")
            _ = try await session.stop()
            try #require(result.termination == .exited(0), "\(result.stderrText)")
        }
        _ = try await gameSettings.setGraphicsBackend(.automatic, appID: 900001)
        try await run(900001, "unset")
        try await run(900002, "0")
        try await run(nil, "0")
        try await settings.selectGraphicsBackend(.automatic)
        _ = try await gameSettings.setGraphicsBackend(.metal3, appID: 900001)
        try await run(900001, "0")
        try await run(900002, "unset")
        try await run(nil, "unset")
        _ = try await gameSettings.setGraphicsBackend(.inherit, appID: 900001)
        try await run(900001, "unset")
        try FileManager.default.removeItem(at: parent)
    }
}
