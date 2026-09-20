import Foundation
import Testing
@testable import GamekitCore

@Suite("Opt-in Windows controller observation")
struct ControllerAcceptanceTests {
    @Test("Observe DirectInput and XInput through an existing owned Steam session",
          .enabled(if: ProcessInfo.processInfo.environment["GAMEKIT_CONTROLLER_PROBE"] != nil))
    func observe() async throws {
        let probe = try #require(ProcessInfo.processInfo.environment["GAMEKIT_CONTROLLER_PROBE"])
        let store = try EnvironmentStore()
        let layout = try await RuntimeSettingsStore(store: store).layout()
        let lifecycle = SteamLifecycle(store: store, layout: layout)
        let record = try #require(await store.load(SteamInstallationRecipe.environmentID))
        let snapshot = try await lifecycle.diagnosticProcesses()
        let tokens = Set(snapshot.processes.compactMap(\.sessionID))
        try #require(tokens.count == 1)
        let token = try #require(tokens.first)
        let installation = try await store.installationLease()
        let lease = try await store.executionLease(for: record.id)
        defer { withExtendedLifetime((installation, lease)) {} }
        try lease.validate()
        let fresh = try await lifecycle.diagnosticProcesses()
        try #require(!fresh.processes.isEmpty && fresh.processes.allSatisfy { $0.sessionID == token })
        let result = try await ProcessExecutor().run(.init(executable: layout.wine, arguments: [probe],
            environment: layout.environment(prefix: lease.prefix, session: token), workingDirectory: lease.prefix,
            timeout: 15, outputLimit: 32768))
        print(result.stdoutText)
        print("This observes Wine devices, not Steam Input's per-game emulation or game acceptance.")
        #expect(result.termination == .exited(0))
    }
}
