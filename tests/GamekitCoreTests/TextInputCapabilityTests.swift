import Foundation
import Testing
@testable import GamekitCore

@Suite("Opt-in Windows text-input capability observation")
struct TextInputCapabilityTests {
    @Test("Observe text-input interfaces and close the scoped probe session",
          .enabled(if: ProcessInfo.processInfo.environment["GAMEKIT_TEXT_INPUT_PROBE"] == "1"))
    func inspectInterfaces() async throws {
        let executable = try #require(ProcessInfo.processInfo.environment["GAMEKIT_TEXT_INPUT_PROBE_PATH"])
        let store = try EnvironmentStore()
        let layout = try await RuntimeSettingsStore(store: store).layout()
        let session = try await RuntimeSession.start(store: store, id: SteamInstallationRecipe.environmentID,
            layout: layout, arguments: [executable], timeout: 60)
        do {
            let result = await session.command.result()
            print(result.stdoutText)
            #expect(result.termination == .exited(0))
            #expect(result.stdoutText.contains("Text-input observation complete"))
            _ = try await session.stop()
            #expect(try await session.snapshot().processes.isEmpty)
        } catch { _ = try await session.stop(); throw error }
    }
}
