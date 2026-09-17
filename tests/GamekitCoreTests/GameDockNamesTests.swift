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
        let layout = RuntimeLayout(dataRoot: store.root, profile: selected.profile, bundle: selected.bundle, identityHelper: helper)
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
        var mapping = GameDockNames(schemaVersion: 1, prefix: lease.prefix.path, sessionID: receipt.token.uuidString,
            games: ["1": name], directories: ["1": windowsDirectory])
        let mapURL = temporary.appendingPathComponent("names.json")
        try JSONEncoder().encode(mapping).write(to: mapURL)
        var environment = layout.environment(prefix: lease.prefix, session: receipt.token.uuidString)
        environment["GAMEKIT_GAME_NAMES_FILE"] = mapURL.path
        var loader = layout.wine
        var probeBundle: (ManagedDirectory, String, (device: Int32, inode: UInt64))?
        defer {
            if let (parent, name, identity) = probeBundle { try? parent.removeStagingDirectory(name, identity: identity) }
        }
        if env["GAMEKIT_DOCK_NAMED_LOADER_PROBE"] == "1" {
            let probeLayout = RuntimeLayout(dataRoot: temporary, profile: selected.profile, bundle: selected.bundle)
            let original = try await SteamApplicationBundle(layout: probeLayout).prepare()
            let bundle = original.deletingLastPathComponent().appendingPathComponent(name + ".app")
            try FileManager.default.moveItem(at: original, to: bundle)
            loader = bundle.appendingPathComponent("Contents/MacOS/\(name)")
            try FileManager.default.moveItem(at: bundle.appendingPathComponent("Contents/MacOS/Windows Steam"), to: loader)
            let plist: [String: Any] = ["CFBundleIdentifier": "tech.endofline.gamekit.probe", "CFBundleExecutable": name,
                "CFBundleName": name, "CFBundleDisplayName": name, "CFBundlePackageType": "APPL", "LSUIElement": true]
            try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
                .write(to: bundle.appendingPathComponent("Contents/Info.plist"))
            environment.removeValue(forKey: "DYLD_INSERT_LIBRARIES")
        } else {
            let defaultBundle = SteamApplicationBundle(layout: layout)
            _ = try await defaultBundle.prepare()
            loader = defaultBundle.executable
            let builder = SteamApplicationBundle(layout: layout, game: .init(appID: UInt32.random(in: 3_000_000_000...4_000_000_000), name: name))
            let bundle = try await builder.prepare()
            let parent = try #require(try ManagedDirectory.openRoot(bundle.deletingLastPathComponent(), create: false))
            let created = try #require(try parent.directory(bundle.lastPathComponent))
            probeBundle = (parent, bundle.lastPathComponent, try created.identity())
            mapping.loaders = ["1": builder.executable.path]
            mapping.defaultLoader = defaultBundle.executable.path
            try JSONEncoder().encode(mapping).write(to: mapURL)
        }
        let request = CommandRequest(executable: loader,
            arguments: ["cmd.exe", "/c", "Z:" + executable.path.replacingOccurrences(of: "/", with: "\\")],
            environment: environment, workingDirectory: lease.prefix, timeout: 15, outputLimit: 4096)
        let running = Task { try await ProcessExecutor().run(request) }
        var observed = false
        for _ in 0..<25 {
            if await MainActor.run(body: { NSWorkspace.shared.runningApplications.contains { $0.localizedName == name } }) { observed = true; break }
            try await Task.sleep(for: .milliseconds(250))
        }
        if observed && env["GAMEKIT_DOCK_NAMED_LOADER_PROBE"] != "1" {
            let pid = await MainActor.run { NSWorkspace.shared.runningApplications.first { $0.localizedName == name }?.processIdentifier }
            let owned = await RuntimeProcessObserver().inspect(record: record, prefix: lease.prefix, layout: layout)
            #expect(owned.complete && owned.processes.contains { $0.identity.pid == pid && $0.sessionID == receipt.token.uuidString },
                    "Routing must retain prefix/session ownership so Stop can still find the game")
        }
        if env["GAMEKIT_DOCK_AX_TEST"] == "1" {
            let script = "tell application \"System Events\" to tell process \"Dock\" to return exists (UI element \"\(name)\" of list 1)"
            var visible = false
            for _ in 0..<10 {
                let dock = try await ProcessExecutor().run(.init(executable: URL(fileURLWithPath: "/usr/bin/osascript"),
                    arguments: ["-e", script], timeout: 5, outputLimit: 1024))
                try #require(dock.termination == .exited(0), "Accessibility permission is required for the visible Dock check")
                if dock.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines) == "true" { visible = true; break }
                try await Task.sleep(for: .milliseconds(200))
            }
            #expect(visible, "The visible Dock label must match, not merely the Launch Services registry")
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
