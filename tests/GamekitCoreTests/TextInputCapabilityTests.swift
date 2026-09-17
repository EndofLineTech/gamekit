import Foundation
import Testing
@testable import GamekitCore

@Suite("Opt-in Windows text-input capability observation")
struct TextInputCapabilityTests {
    @Test("Observe text-input interfaces and close the scoped probe session",
          .enabled(if: ProcessInfo.processInfo.environment["GAMEKIT_TEXT_INPUT_PROBE"] == "1"))
    func inspectInterfaces() async throws {
        let executable = try #require(ProcessInfo.processInfo.environment["GAMEKIT_TEXT_INPUT_PROBE_PATH"])
        let experiment = try HelldiversTextInputExperiment.root()
        let store = try EnvironmentStore(root: experiment?.appendingPathComponent("Gamekit") ?? EnvironmentStore.applicationSupportRoot)
        let layout: RuntimeLayout
        if let experiment { layout = HelldiversTextInputExperiment.layout(root: experiment) }
        else { layout = try await RuntimeSettingsStore(store: store).layout() }
        var arguments = [executable]
        if let candidate = ProcessInfo.processInfo.environment["GAMEKIT_TEXT_INPUT_DLL"] {
            try #require(candidate.hasPrefix("/") && FileManager.default.fileExists(atPath: candidate))
            arguments.append("Z:" + candidate)
        }
        let session = try await RuntimeSession.start(store: store, id: SteamInstallationRecipe.environmentID,
            layout: layout, arguments: arguments, timeout: 60)
        do {
            let result = await session.command.result()
            print(result.stdoutText)
            #expect(result.termination == .exited(0))
            #expect(result.stdoutText.contains("Text-input observation complete"))
            if let expected = ProcessInfo.processInfo.environment["GAMEKIT_TEXT_INPUT_EXPECT_AVAILABLE"] {
                #expect(["0", "1"].contains(expected))
                #expect(result.stdoutText.contains("Text-input reconversion available=" + expected))
            }
            _ = try await session.stop()
            #expect(try await session.snapshot().processes.isEmpty)
        } catch { _ = try await session.stop(); throw error }
    }
}
