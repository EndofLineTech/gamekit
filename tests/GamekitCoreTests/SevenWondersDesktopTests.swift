import Foundation
import CoreGraphics
import Testing
@testable import GamekitCore

@Suite("Opt-in 7 Wonders II desktop compatibility")
struct SevenWondersDesktopTests {
    @Test("Observe an explicit virtual desktop using only a small disposable game copy",
          .enabled(if: ProcessInfo.processInfo.environment["GAMEKIT_SEVEN_WONDERS_TRIAL"] == "1"))
    func observe() async throws {
        try #require(CGPreflightScreenCaptureAccess())
        let evidenceURL = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["GAMEKIT_SEVEN_WONDERS_EVIDENCE"]))
        let evidenceParent = try #require(try ManagedDirectory.openRoot(evidenceURL.deletingLastPathComponent(), create: false))
        _ = try evidenceParent.createExclusiveDirectory(evidenceURL.lastPathComponent)
        let primary = try EnvironmentStore()
        let selected = try await RuntimeSettingsStore(store: primary).layout()
        let record = try #require(await primary.load(SteamInstallationRecipe.environmentID))
        let prefix = primary.prefixURL(for: record.id)
        let game = try #require(try SteamGameLibrary.scan(prefix: prefix, steamExecutable: record.steamExecutable).games.first { $0.id == 15900 && $0.state == .ready })
        let source = prefix.appendingPathComponent(record.steamExecutable.rawValue).deletingLastPathComponent()
            .appendingPathComponent("steamapps/common").appendingPathComponent(game.installDirectory)
        let root = try ManagedDirectory.canonicalRoot(FileManager.default.temporaryDirectory.appendingPathComponent("Gamekit legacy game " + UUID().uuidString))
        let store = try EnvironmentStore(root: root)
        let layout = RuntimeLayout(dataRoot: root, profile: selected.profile, bundle: selected.bundle, graphicsBackend: selected.graphicsBackend)
        let id = try EnvironmentID("seven-wonders-probe")
        _ = try await store.create(.init(id: id, name: "7 Wonders desktop trial", runtime: layout.profile.identity, installation: .installing(.creatingPrefix)))
        let directory = try #require(try ManagedDirectory.openRoot(root, create: false))
        let copy = try directory.createExclusiveDirectory("Game")
        try copy.copyContents(from: #require(try ManagedDirectory.openRoot(source, create: false)))
        try FileManager.default.createDirectory(at: store.prefixURL(for: id), withIntermediateDirectories: true)
        let executable = root.appendingPathComponent("Game/WondersII_1_13.exe")
        let session = try await RuntimeSession.start(store: store, id: id, layout: layout,
            arguments: ["explorer.exe", "/desktop=Gamekit15900Trial,800x600", "Z:" + executable.path.replacingOccurrences(of: "/", with: "\\")],
            workingDirectory: executable.deletingLastPathComponent(), timeout: 60)
        func cleanup() async throws {
            _ = try await session.stop()
            let stopped = try await session.snapshot()
            try #require(stopped.complete && stopped.processes.isEmpty)
            try FileManager.default.removeItem(at: root)
            print("Disposable game copy and prefix removed after verified shutdown")
        }
        do {
            for sample in 0..<6 {
                try await Task.sleep(for: .seconds(5))
                let snapshot = try await session.snapshot()
                try #require(snapshot.complete)
                let pids = Set(snapshot.processes.map(\.identity.pid))
                let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
                for (index, window) in windows.filter({ pids.contains($0[kCGWindowOwnerPID as String] as? Int32 ?? 0) }).prefix(4).enumerated() {
                    guard let number = window[kCGWindowNumber as String] as? UInt32 else { continue }
                    _ = try await ProcessExecutor().run(.init(executable: URL(fileURLWithPath: "/usr/sbin/screencapture"),
                        arguments: ["-x", "-o", "-l", String(number), evidenceURL.appendingPathComponent("sample-\(sample)-\(index).png").path],
                        timeout: 5, outputLimit: 1024))
                }
            }
            try await cleanup()
        } catch {
            try await cleanup()
            throw error
        }
        let result = await session.command.result()
        print("Bounded observation termination: \(result.termination)\n\(result.stdoutText)\n\(result.stderrText)")
    }

    @Test("Configure only the game's named desktop through scoped Wine registry calls",
          .enabled(if: ProcessInfo.processInfo.environment["GAMEKIT_SEVEN_WONDERS_DESKTOP"] != nil))
    func configure() async throws {
        let env = ProcessInfo.processInfo.environment
        let mode = try #require(env["GAMEKIT_SEVEN_WONDERS_DESKTOP"])
        try #require(["query", "apply", "restore"].contains(mode))
        let tool = try #require(env["GAMEKIT_SEVEN_WONDERS_DESKTOP_TOOL"])
        let store = try EnvironmentStore()
        let layout = try await RuntimeSettingsStore(store: store).layout()
        let id = SteamInstallationRecipe.environmentID
        let record = try #require(await store.load(id))
        let snapshot = await RuntimeProcessObserver().inspect(record: record, prefix: store.prefixURL(for: id), layout: layout)
        try #require(snapshot.complete && !snapshot.processes.contains { $0.role == .other }, "Close games before changing desktop settings")
        _ = try await SteamLifecycle(store: store, layout: layout).stop()
        let session = try await RuntimeSession.start(store: store, id: id, layout: layout, arguments: [tool, mode], timeout: 30)
        let result = await session.command.result()
        _ = try await session.stop()
        let stopped = try await session.snapshot()
        try #require(stopped.complete && stopped.processes.isEmpty)
        print(result.stdoutText)
        #expect(result.termination == .exited(0))
    }
}
