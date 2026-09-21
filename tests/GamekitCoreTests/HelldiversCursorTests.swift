import Foundation
import Testing
@testable import GamekitCore

@Suite("Opt-in Helldivers cursor capture comparison")
struct HelldiversCursorTests {
    @Test("Query or change only the game's mouse/fullscreen capture overrides while the prefix is idle",
          .enabled(if: ProcessInfo.processInfo.environment["GAMEKIT_CURSOR_OVERRIDE"] != nil))
    func configure() async throws {
        let env = ProcessInfo.processInfo.environment
        let action = try #require(env["GAMEKIT_CURSOR_OVERRIDE"])
        try #require(["query", "event-tap", "restore-default", "query-display", "capture-display", "restore-display"].contains(action))
        let executable = try #require(env["GAMEKIT_CURSOR_PROBE_PATH"])
        let expectedExit = try #require(Int32(env["GAMEKIT_CURSOR_EXPECT_EXIT"] ?? "0"))
        try #require(expectedExit == 0 || expectedExit == 1)
        let store = try EnvironmentStore()
        let layout = try await RuntimeSettingsStore(store: store).layout()
        let session = try await RuntimeSession.start(store: store, id: SteamInstallationRecipe.environmentID,
            layout: layout, arguments: [executable, action, GameFixtures.primary.executable], timeout: 30)
        do {
            let result = await session.command.result()
            print(result.stdoutText)
            #expect(result.termination == .exited(expectedExit))
            if expectedExit == 1 { #expect(result.stdoutText.contains("Refused: existing preference")) }
            if let expected = env["GAMEKIT_CURSOR_EXPECT"] {
                try #require(["absent", "event-tap", "enabled", "disabled", "existing-other"].contains(expected))
                let label = action.contains("display") ? "display_capture=" : "cursor_override="
                #expect(result.stdoutText.contains(label + expected))
            }
            _ = try await session.stop()
            #expect(try await session.snapshot().processes.isEmpty)
        } catch { _ = try await session.stop(); throw error }
    }
}
