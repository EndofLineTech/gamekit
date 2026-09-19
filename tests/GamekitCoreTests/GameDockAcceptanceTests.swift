import AppKit
import CProcessSupport
import Foundation
import Testing
@testable import GamekitCore

@Suite("Opt-in Satisfactory Dock acceptance")
struct GameDockAcceptanceTests {
    @Test("Satisfactory gets its filesystem Dock name and is always closed after the check",
          .enabled(if: ProcessInfo.processInfo.environment["GAMEKIT_SATISFACTORY_DOCK_ACCEPTANCE"] == "1"))
    func satisfactory() async throws {
        let helper = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["GAMEKIT_IDENTITY_X86_HELPER"]))
        try #require(CGPreflightScreenCaptureAccess(), "Window inventory requires screen-capture permission")
        let store = try EnvironmentStore()
        let selected = try await RuntimeSettingsStore(store: store).layout()
        let layout = RuntimeLayout(dataRoot: store.root, profile: selected.profile, bundle: selected.bundle,
            identityHelper: helper, graphicsBackend: selected.graphicsBackend)
        let lifecycle = SteamLifecycle(store: store, layout: layout)
        let record = try #require(await store.load(SteamInstallationRecipe.environmentID))
        let prefix = store.prefixURL(for: record.id)
        func closeSession() async throws {
            let snapshot = await RuntimeProcessObserver().inspect(record: record, prefix: prefix, layout: layout)
            if snapshot.complete {
                let gamePIDs = Set(snapshot.processes.filter { $0.role == .other }.map { $0.identity.pid })
                await MainActor.run {
                    for app in NSWorkspace.shared.runningApplications where gamePIDs.contains(app.processIdentifier) && app.activationPolicy == .regular {
                        _ = app.terminate()
                    }
                }
                try await Task.sleep(for: .seconds(3))
            }
            let stopped = try await lifecycle.stop()
            print("Satisfactory acceptance cleanup: \(stopped)")
            #expect(try await lifecycle.status() == .stopped)
        }

        _ = try await lifecycle.stop() // User authorized a fresh session for testing.
        do {
            try await lifecycle.launchGame(appID: 526870)
            var found = false
            // Cold Steam initialization can delay the game beyond 45 seconds.
            // Match the bounded 90-second startup observation used for games.
            for _ in 0..<180 {
                let snapshot = await RuntimeProcessObserver().inspect(record: record, prefix: prefix, layout: layout)
                var gamePIDs = Set<Int32>()
                for process in snapshot.processes where process.role == .other {
                    var buffer: UnsafeMutablePointer<CChar>?, length = 0
                    guard gk_arguments(process.identity.pid, &buffer, &length) == 0, let buffer else { continue }
                    let arguments = KernelArguments(bytes: Data(bytes: buffer, count: length))?.arguments ?? []
                    gk_free(buffer)
                    if arguments.contains(where: { $0.lowercased().hasSuffix("factorygamesteam-win64-shipping.exe") }) { gamePIDs.insert(process.identity.pid) }
                }
                let identified = gamePIDs
                let names = await MainActor.run {
                    NSWorkspace.shared.runningApplications.filter { identified.contains($0.processIdentifier) && $0.activationPolicy == .regular && $0.localizedName == "Satisfactory" }.map(\.processIdentifier)
                }
                if !names.isEmpty { found = true; break }
                try await Task.sleep(for: .milliseconds(500))
            }
            #expect(found, "The actual Satisfactory process must have the game identity")
            let owned = await RuntimeProcessObserver().inspect(record: record, prefix: prefix, layout: layout)
            try #require(owned.complete)
            let ownedPIDs = Set(owned.processes.map(\.identity.pid))
            let unexpectedSpaceHost = await MainActor.run {
                (CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] ?? []).contains {
                    guard let pid = $0[kCGWindowOwnerPID as String] as? Int32, ownedPIDs.contains(pid) else { return false }
                    return $0[kCGWindowName as String] as? String == "Gamekit fullscreen Space"
                }
            }
            #expect(!unexpectedSpaceHost, "Helldivers' presentation preference must not create a Space for Satisfactory or Steam")
            let dock = try await ProcessExecutor().run(.init(executable: URL(fileURLWithPath: "/usr/bin/osascript"),
                arguments: ["-e", "tell application \"System Events\" to tell process \"Dock\" to return count of (UI elements of list 1 whose name is \"Satisfactory\")"],
                timeout: 5, outputLimit: 1024))
            #expect(dock.termination == .exited(0))
            #expect(dock.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines) == "1", "The actual Dock must show one Satisfactory entry")
            try await lifecycle.show()
            try await Task.sleep(for: .seconds(2))
            let steamDock = try await ProcessExecutor().run(.init(executable: URL(fileURLWithPath: "/usr/bin/osascript"),
                arguments: ["-e", "tell application \"System Events\" to tell process \"Dock\" to return count of (UI elements of list 1 whose name is \"Windows Steam\")"],
                timeout: 5, outputLimit: 1024))
            #expect(steamDock.termination == .exited(0))
            #expect(steamDock.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines) == "1", "Steam must keep its separate identity")
            print("Live Dock counts: Satisfactory=\(dock.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)), Windows Steam=\(steamDock.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines))")
        } catch {
            try await closeSession()
            throw error
        }
        try await closeSession()
    }
}
