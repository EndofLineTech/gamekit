import Foundation
import Testing
@testable import GamekitCore

@Suite("Opt-in managed runtime revision acceptance")
struct RuntimeRevisionAcceptanceTests {
    @Test("Switch and roll back the real stopped prefix without replacing its DLLs",
          .enabled(if: ProcessInfo.processInfo.environment["GAMEKIT_RUNTIME_REVISION_ACCEPTANCE"] == "1"))
    func switchAndRollback() async throws {
        let probe = try #require(ProcessInfo.processInfo.environment["GAMEKIT_TEXT_INPUT_PROBE_PATH"])
        let store = try EnvironmentStore()
        let settings = RuntimeSettingsStore(store: store)
        let original = try await settings.layout()
        try #require(original.profile.revision == .original)
        let id = SteamInstallationRecipe.environmentID
        let record = try #require(await store.load(id))
        let prefixDLL = store.prefixURL(for: id).appendingPathComponent("drive_c/windows/system32/msctf.dll")
        let before = try Data(contentsOf: prefixDLL)

        func inspect(_ layout: RuntimeLayout, expected: String) async throws {
            let session = try await RuntimeSession.start(store: store, id: id, layout: layout, arguments: [probe], timeout: 60)
            do {
                let result = await session.command.result()
                print(result.stdoutText)
                #expect(result.termination == .exited(0))
                #expect(result.stdoutText.contains("Text-input reconversion available=" + expected))
                _ = try await session.stop()
                #expect(try await session.snapshot().processes.isEmpty)
            } catch { _ = try await session.stop(); throw error }
        }

        do {
            try await settings.select(nil, revision: .textInput1)
            try await inspect(settings.layout(), expected: "1")
            #expect(try Data(contentsOf: prefixDLL) == before)
            #expect(try await store.load(id) == record)
        } catch {
            try await settings.select(original.bundle, revision: original.profile.revision)
            throw error
        }
        try await settings.select(original.bundle, revision: .original)
        try await inspect(settings.layout(), expected: "0")
        #expect(try Data(contentsOf: prefixDLL) == before)
        #expect(try await store.load(id) == record)
        print("Real prefix revision switch and rollback passed; prefix DLL and environment record unchanged")
    }
}
