import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import GamekitCore

@Suite("Opt-in Steam library inventory")
struct SteamLibraryInventoryTests {
    @Test("Request a read-only license listing from the owned Steam client",
          .enabled(if: ProcessInfo.processInfo.environment["GAMEKIT_EXPORT_STEAM_LICENSES"] == "1"))
    func inventory() async throws {
        let store = try EnvironmentStore()
        let selected = try await RuntimeSettingsStore(store: store).layout()
        let package = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["GAMEKIT_INVENTORY_PACKAGE"]))
        let layout = RuntimeLayout(dataRoot: store.root, profile: selected.profile, bundle: selected.bundle,
            identityHelper: package.appendingPathComponent("Contents/Frameworks/WineGameIdentity.dylib"), graphicsBackend: selected.graphicsBackend)
        let lifecycle = SteamLifecycle(store: store, layout: layout)
        let record = try #require(await store.load(SteamInstallationRecipe.environmentID))
        let prefix = store.prefixURL(for: record.id)
        let initial = await RuntimeProcessObserver().inspect(record: record, prefix: prefix, layout: layout)
        try #require(initial.complete && !initial.processes.contains { $0.role == .other })
        do {
            _ = try await lifecycle.launch()
            let snapshot = try await lifecycle.diagnosticProcesses()
            let sessions = Set(snapshot.processes.compactMap(\.sessionID))
            try #require(sessions.count == 1)
            let session = try #require(sessions.first)
            let steam = prefix.appendingPathComponent(record.steamExecutable.rawValue)
            let opened = try await ProcessExecutor().run(.init(executable: layout.wine,
                arguments: [steam.path, "steam://nav/console"], environment: layout.environment(prefix: prefix, session: session),
                workingDirectory: steam.deletingLastPathComponent(), timeout: 15, outputLimit: 4096))
            try #require(opened.termination == .exited(0))
            try await Task.sleep(for: .seconds(3))
            let fresh = try await lifecycle.diagnosticProcesses()
            let owned = Set(fresh.processes.filter { $0.sessionID == session }.map(\.identity.pid))
            let pid = try #require(await MainActor.run {
                NSWorkspace.shared.runningApplications.first { owned.contains($0.processIdentifier) && $0.activationPolicy == .regular && $0.localizedName == "Windows Steam" }?.processIdentifier
            })
            let command = try await ProcessExecutor().run(.init(executable: URL(fileURLWithPath: "/usr/bin/osascript"),
                arguments: ["-e", "tell application \"System Events\" to tell (first application process whose unix id is \(pid))\nset frontmost to true\ndelay 1\nkeystroke \"licenses_print\"\nkey code 36\nend tell"], timeout: 10, outputLimit: 4096))
            try #require(command.termination == .exited(0))
            try await Task.sleep(for: .seconds(5))
            print("License listing requested; inspect the private Steam console log")
            _ = try await lifecycle.stop()
        } catch {
            _ = try await lifecycle.stop()
            throw error
        }
    }
}
