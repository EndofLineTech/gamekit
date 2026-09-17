import Foundation
import CProcessSupport
import Testing
@testable import GamekitCore

@Suite("Game Dock identity mapping")
struct GameDockNamesTests {
    @Test("Inspect game AppIDs in owned Wine process environments", .enabled(if: ProcessInfo.processInfo.environment["GAMEKIT_DOCK_INSPECTION"] == "1"))
    func liveAppIDs() async throws {
        let store = try EnvironmentStore()
        let record = try #require(await store.load(SteamInstallationRecipe.environmentID))
        let layout = try await RuntimeSettingsStore(store: store).layout()
        let snapshot = await RuntimeProcessObserver().inspect(record: record, prefix: store.prefixURL(for: record.id), layout: layout)
        try #require(snapshot.complete)
        try #require(snapshot.processes.contains { $0.role == .other }, "Start a managed game before opting into Dock inspection")
        for process in snapshot.processes where process.role == .other {
            var buffer: UnsafeMutablePointer<CChar>?, length = 0
            guard gk_arguments(process.identity.pid, &buffer, &length) == 0, let buffer else { continue }
            let bytes = Data(bytes: buffer, count: length)
            gk_free(buffer)
            let values = bytes.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
                .filter { $0.hasPrefix("SteamAppId=") || $0.hasPrefix("SteamGameId=") }
            print("Owned other-process pid=\(process.identity.pid), Steam IDs=\(values)")
        }
    }

    @Test("Atomic mappings bind names to a prefix and session and replace old sessions")
    func mapping() throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        let store = try EnvironmentStore(root: parent.appendingPathComponent("Gamekit"))
        let prefix = store.prefixURL(for: SteamInstallationRecipe.environmentID)
        let first = UUID(), second = UUID()
        let game = InstalledSteamGame(id: 526870, name: "Satisfactory", buildID: nil, state: .ready, artwork: nil)
        try GameDockNames.publish(root: store.root, prefix: prefix, session: first, games: [game], validate: {})
        let path = GameDockNames.url(root: store.root, prefix: prefix)
        var map = try JSONDecoder().decode(GameDockNames.self, from: Data(contentsOf: path))
        #expect(map.prefix == prefix.path && map.sessionID == first.uuidString)
        #expect(map.games == ["526870": "Satisfactory"])
        try GameDockNames.publish(root: store.root, prefix: prefix, session: second, games: [], validate: {})
        map = try JSONDecoder().decode(GameDockNames.self, from: Data(contentsOf: path))
        #expect(map.sessionID == second.uuidString && map.games.isEmpty)
    }

    @Test("Only a present regular helper enables the controlled identity environment")
    func environment() throws {
        let parent = try ManagedDirectory.canonicalRoot(FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        let helper = parent.appendingPathComponent("libWineGameIdentity.dylib")
        let prefix = parent.appendingPathComponent("Environments/steam")
        let layout = RuntimeLayout(dataRoot: parent, identityHelper: helper)
        let inherited = ["DYLD_INSERT_LIBRARIES": "/unrelated/library", "GAMEKIT_GAME_NAMES_FILE": "/unrelated/names", "SteamAppId": "1"]
        #expect(layout.environment(prefix: prefix, session: "ours", inheriting: inherited)["DYLD_INSERT_LIBRARIES"] == nil)
        try Data("fixture".utf8).write(to: helper)
        let env = layout.environment(prefix: prefix, session: "ours", inheriting: inherited)
        #expect(env["DYLD_INSERT_LIBRARIES"] == helper.path)
        #expect(env["GAMEKIT_GAME_NAMES_FILE"] == GameDockNames.url(root: parent, prefix: prefix).path)
        #expect(env["SteamAppId"] == nil, "Steam assigns the child AppID; the host cannot inject it")
        #expect(layout.environment(inheriting: inherited)["DYLD_INSERT_LIBRARIES"] == nil)
    }
}
