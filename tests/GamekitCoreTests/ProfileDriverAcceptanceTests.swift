import Foundation
import Testing
@testable import GamekitCore

@Suite("Opt-in generic profile driver acceptance")
struct ProfileDriverAcceptanceTests {
    @Test("Unknown AppID uses JSON parameters through the real derived Wine loader",
          .enabled(if: ProcessInfo.processInfo.environment["GAMEKIT_PROFILE_DRIVER_PROBE"] != nil))
    func liveAdapter() async throws {
        let probe = try #require(ProcessInfo.processInfo.environment["GAMEKIT_PROFILE_DRIVER_PROBE"])
        let helper = try #require(ProcessInfo.processInfo.environment["GAMEKIT_PROFILE_IDENTITY_HELPER"])
        let selected = try await RuntimeSettingsStore(store: EnvironmentStore()).layout()
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("Gamekit profile probe " + UUID().uuidString)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let store = try EnvironmentStore(root: parent.appendingPathComponent("Gamekit"))
        let id = try EnvironmentID("profile-probe")
        _ = try await store.create(EnvironmentRecord(id: id, name: "Profile fixture", runtime: selected.profile.identity,
            installation: .installing(.creatingPrefix)))
        let prefix = store.prefixURL(for: id)
        let steam = prefix.appendingPathComponent("drive_c/Program Files (x86)/Steam")
        let apps = steam.appendingPathComponent("steamapps")
        let game = apps.appendingPathComponent("common/Fixture")
        try FileManager.default.createDirectory(at: game, withIntermediateDirectories: true)
        try Data("fixture".utf8).write(to: steam.appendingPathComponent("Steam.exe"))
        try FileManager.default.copyItem(at: URL(fileURLWithPath: probe), to: game.appendingPathComponent("gamekit-dxgi-probe.exe"))
        try Data(#""AppState" { "appid" "42" "name" "Profile fixture" "installdir" "Fixture" "StateFlags" "4" }"#.utf8)
            .write(to: apps.appendingPathComponent("appmanifest_42.acf"))
        let profile = try #require(GameProfileStore.bundled(appID: GameFixtures.primary.appId))
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(profile)) as? [String: Any])
        object["appId"] = 42; object["name"] = "Profile fixture"; object["revision"] = 99
        var execution = try #require(object["execution"] as? [String: Any])
        execution["executable"] = "gamekit-dxgi-probe.exe"
        var driver = try #require(execution["driver"] as? [String: Any])
        driver["replacementVersion"] = GameFixtures.syntheticVersion
        execution["driver"] = driver; object["execution"] = execution
        try await GameProfileStore(root: store.root).accept(JSONSerialization.data(withJSONObject: object), appID: 42)
        let layout = RuntimeLayout(dataRoot: store.root, profile: selected.profile, bundle: selected.bundle,
                                   identityHelper: URL(fileURLWithPath: helper), graphicsBackend: .metal3)
        let session = try await RuntimeSession.startGameProbe(store: store, id: id, layout: layout,
            game: .init(appID: 42, name: "Profile fixture"),
            arguments: [#"C:\Program Files (x86)\Steam\steamapps\common\Fixture\gamekit-dxgi-probe.exe"#, GameFixtures.syntheticHex])
        do {
            _ = try await session.waitUntilStopped()
            let result = try await session.stop()
            print(result.stdoutText)
            #expect(result.termination == .exited(0))
            #expect(result.stdoutText.contains("version=" + GameFixtures.syntheticHex))
            #expect(result.stdoutText.contains("D3D12CreateDevice hr=00000000"))
            try #require(try await session.snapshot().processes.isEmpty)
            try FileManager.default.removeItem(at: parent)
        } catch {
            _ = try? await session.stop()
            throw error
        }
    }
}
