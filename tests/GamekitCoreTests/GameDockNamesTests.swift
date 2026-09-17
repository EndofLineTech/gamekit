import Foundation
import CProcessSupport
import AppKit
import Testing
@testable import GamekitCore

@Suite("Game Dock identity mapping")
struct GameDockNamesTests {
    @Test("Real Wine child is named without a native SteamAppId", .enabled(if: ProcessInfo.processInfo.environment["GAMEKIT_WINE_DOCK_PROBE"] == "1"))
    func liveWineName() async throws {
        let env = ProcessInfo.processInfo.environment
        let helper = URL(fileURLWithPath: try #require(env["GAMEKIT_IDENTITY_X86_HELPER"]))
        let executable = URL(fileURLWithPath: try #require(env["GAMEKIT_WINE_DOCK_PROBE_PATH"]))
        let store = try EnvironmentStore()
        let selected = try await RuntimeSettingsStore(store: store).layout()
        let layout = RuntimeLayout(dataRoot: store.root, bundle: selected.bundle, identityHelper: helper)
        let installation = try await store.installationLease()
        defer { withExtendedLifetime(installation) {} }
        let id = SteamInstallationRecipe.environmentID
        let record = try #require(await store.load(id))
        let lease = try await store.executionLease(for: id)
        defer { withExtendedLifetime(lease) {} }
        let root = try #require(try ManagedDirectory.openRoot(store.root, create: false))
        let data = try #require(try root.directory("Metadata")?.directory("Lifecycle")?.read("steam.json"))
        struct Receipt: Decodable { let token: UUID; let device: Int32; let inode: UInt64 }
        let receipt = try JSONDecoder().decode(Receipt.self, from: data)
        try #require(receipt.device == lease.prefixIdentity.device && receipt.inode == lease.prefixIdentity.inode)
        let before = await RuntimeProcessObserver().inspect(record: record, prefix: lease.prefix, layout: layout)
        try #require(before.complete && !before.processes.isEmpty && before.processes.allSatisfy { $0.sessionID == receipt.token.uuidString })
        let temporary = try ManagedDirectory.canonicalRoot(FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let name = "Gamekit Wine Probe " + UUID().uuidString.prefix(8)
        let windowsDirectory = "z:" + executable.deletingLastPathComponent().path.replacingOccurrences(of: "/", with: "\\") + "\\"
        let mapping = GameDockNames(schemaVersion: 1, prefix: lease.prefix.path, sessionID: receipt.token.uuidString,
            games: ["1": name], directories: ["1": windowsDirectory])
        let mapURL = temporary.appendingPathComponent("names.json")
        try JSONEncoder().encode(mapping).write(to: mapURL)
        var environment = layout.environment(prefix: lease.prefix, session: receipt.token.uuidString)
        environment["GAMEKIT_GAME_NAMES_FILE"] = mapURL.path
        let request = CommandRequest(executable: layout.wine,
            arguments: ["Z:" + executable.path.replacingOccurrences(of: "/", with: "\\")],
            environment: environment, workingDirectory: lease.prefix, timeout: 15, outputLimit: 4096)
        let running = Task { try await ProcessExecutor().run(request) }
        var observed = false
        for _ in 0..<25 {
            if await MainActor.run(body: { NSWorkspace.shared.runningApplications.contains { $0.localizedName == name } }) { observed = true; break }
            try await Task.sleep(for: .milliseconds(250))
        }
        let result = try await running.value
        #expect(result.termination == .exited(0))
        #expect(observed, "The actual Wine child must publish the mapped Dock name")
        try lease.validate()
    }

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
            let fields = bytes.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
            let values = fields.filter { $0.hasPrefix("SteamAppId=") || $0.hasPrefix("SteamGameId=") }
            let parsed = KernelArguments(bytes: bytes)
            let images = (parsed?.arguments ?? []).filter { $0.lowercased().hasSuffix(".exe") }.map {
                $0.replacingOccurrences(of: "\\", with: "/").components(separatedBy: "/").last ?? "unknown"
            }
            print("Owned other-process pid=\(process.identity.pid), images=\(images), Steam IDs=\(values), helperEnv=\(fields.contains { $0.hasPrefix("DYLD_INSERT_LIBRARIES=") }), mapEnv=\(fields.contains { $0.hasPrefix("GAMEKIT_GAME_NAMES_FILE=") })")
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
        let game = InstalledSteamGame(id: 526870, name: "Satisfactory", installDirectory: "Satisfactory", buildID: nil, state: .ready, artwork: nil)
        try GameDockNames.publish(root: store.root, prefix: prefix, session: first, games: [game], validate: {})
        let path = GameDockNames.url(root: store.root, prefix: prefix)
        var map = try JSONDecoder().decode(GameDockNames.self, from: Data(contentsOf: path))
        #expect(map.prefix == prefix.path && map.sessionID == first.uuidString)
        #expect(map.games == ["526870": "Satisfactory"])
        #expect(map.directories["526870"] == "c:\\Program Files (x86)\\Steam\\steamapps\\common\\Satisfactory\\")
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
