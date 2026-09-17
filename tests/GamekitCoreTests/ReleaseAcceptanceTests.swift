import Foundation
import AppKit
import Testing
@testable import GamekitCore

@Suite("Opt-in E5 acceptance setup")
struct ReleaseAcceptanceTests {
    @Test("Isolated acceptance launch/stop cycles preserve one usable Steam UI", .enabled(if: ProcessInfo.processInfo.environment["GAMEKIT_ACCEPTANCE_CYCLE"] == "1"))
    @MainActor func acceptanceLifecycle() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["GAMEKIT_ACCEPTANCE_ROOT"])
        let store = try EnvironmentStore(root: URL(fileURLWithPath: path))
        try #require(store.root.path.hasPrefix(EnvironmentStore.applicationSupportRoot.appendingPathComponent("Acceptance").path + "/"))
        let record = try #require(await store.load(SteamInstallationRecipe.environmentID))
        try #require(record.installation == .installed)
        let layout = try await RuntimeSettingsStore(store: store).layout()
        for cycle in 1...2 {
            let lifecycle = SteamLifecycle(store: store, layout: layout)
            _ = try await lifecycle.stop()
            _ = try await lifecycle.launch()
            var ready = false
            for _ in 0..<120 {
                let snapshot = await RuntimeProcessObserver().inspect(record: record, prefix: store.prefixURL(for: record.id), layout: layout)
                if SteamReadiness.ready(snapshot: snapshot, windowOwners: SteamReadiness.windowOwners()) { ready = true; break }
                try await Task.sleep(for: .milliseconds(500))
            }
            #expect(ready)
            try await Task.sleep(for: .seconds(10))
            let snapshot = await RuntimeProcessObserver().inspect(record: record, prefix: store.prefixURL(for: record.id), layout: layout)
            #expect(SteamReadiness.ready(snapshot: snapshot, windowOwners: SteamReadiness.windowOwners()))
            let pids = Set(snapshot.processes.map { $0.identity.pid })
            let foreground = NSWorkspace.shared.runningApplications.filter { pids.contains($0.processIdentifier) && $0.activationPolicy == .regular }
            print("Acceptance cycle \(cycle): foreground=\(foreground.map { $0.localizedName ?? "?" })")
            #expect(foreground.count == 1)
            _ = try await lifecycle.stop()
            #expect(try await lifecycle.status() == .stopped)
        }
    }

    @Test("Verify automatic installed state and web UI in the isolated acceptance root", .enabled(if: ProcessInfo.processInfo.environment["GAMEKIT_VERIFY_ACCEPTANCE"] == "1"))
    @MainActor func verifyAutomaticAcceptance() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["GAMEKIT_ACCEPTANCE_ROOT"])
        let store = try EnvironmentStore(root: URL(fileURLWithPath: path))
        try #require(store.root.path.hasPrefix(EnvironmentStore.applicationSupportRoot.appendingPathComponent("Acceptance").path + "/"))
        let record = try #require(await store.load(SteamInstallationRecipe.environmentID))
        #expect(record.installation == .installed)
        let layout = try await RuntimeSettingsStore(store: store).layout()
        let snapshot = await RuntimeProcessObserver().inspect(record: record, prefix: store.prefixURL(for: record.id), layout: layout)
        #expect(SteamReadiness.ready(snapshot: snapshot, windowOwners: SteamReadiness.windowOwners()))
        let pids = Set(snapshot.processes.map { $0.identity.pid })
        let foreground = NSWorkspace.shared.runningApplications.filter { pids.contains($0.processIdentifier) && $0.activationPolicy == .regular }
        print("Acceptance foreground apps: \(foreground.map { "\($0.processIdentifier):\($0.localizedName ?? "?")" })")
        try #require(foreground.count == 1 && foreground.allSatisfy { $0.localizedName == "Windows Steam" })
        print("Automatic acceptance verified: revision=\(record.revision), client/web UI/window evidence present")
    }

    @Test("Prepare an isolated acceptance root using the selected validated runtime", .enabled(if: ProcessInfo.processInfo.environment["GAMEKIT_PREPARE_ACCEPTANCE"] == "1"))
    func prepareAcceptanceRoot() async throws {
        let primary = try EnvironmentStore()
        let selected = try await RuntimeSettingsStore(store: primary).layout()
        let report = try await RuntimeDetector().detect(selected, selection: selected.profile.identity)
        try #require(report.prerequisites == .ready)
        let parent = primary.root.appendingPathComponent("Acceptance")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let root = parent.appendingPathComponent("E5 acceptance " + UUID().uuidString.lowercased())
        let store = try EnvironmentStore(root: root)
        try await RuntimeSettingsStore(store: store).select(selected.bundle, revision: selected.profile.revision)
        #expect(try await store.loadAll().isEmpty)
        print("E5_ACCEPTANCE_ROOT=\(store.root.path)")
    }
}
