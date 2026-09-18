import Foundation
import Testing
@testable import GamekitCore

@Suite("Opt-in managed runtime revision acceptance")
struct RuntimeRevisionAcceptanceTests {
    @Test("Validate driver revision, rollback, and select it on the real stopped prefix",
          .enabled(if: ProcessInfo.processInfo.environment["GAMEKIT_DRIVER_REVISION_ACCEPTANCE"] == "1"))
    func driverSwitchAndRollback() async throws {
        let probe = try #require(ProcessInfo.processInfo.environment["GAMEKIT_DRIVER_PROBE_PATH"])
        try #require(URL(fileURLWithPath: probe).lastPathComponent == "helldivers2.exe")
        let store = try EnvironmentStore()
        let settings = RuntimeSettingsStore(store: store)
        let old = try await settings.layout()
        try #require(old.profile.revision == .textInput1 && old.graphicsBackend == .metal3)
        let prefix = store.prefixURL(for: SteamInstallationRecipe.environmentID)
        let dll = prefix.appendingPathComponent("drive_c/windows/system32/dxgi.dll")
        let originalDLL = try Data(contentsOf: dll)

        func select(_ revision: RuntimeRevision, bundle: URL? = nil) async throws -> RuntimeLayout {
            let registry = try Data(contentsOf: prefix.appendingPathComponent("user.reg"))
            try await settings.select(bundle, revision: revision)
            #expect(try Data(contentsOf: dll) == originalDLL)
            #expect(try Data(contentsOf: prefix.appendingPathComponent("user.reg")) == registry)
            return try await settings.layout()
        }
        func inspect(_ layout: RuntimeLayout, appID: UInt32, expected: String) async throws {
            let session = try await RuntimeSession.startGameProbe(store: store, id: SteamInstallationRecipe.environmentID,
                layout: layout, game: .init(appID: appID, name: appID == 553850 ? "HELLDIVERS™ 2" : "Driver control"), arguments: [probe, expected])
            let result = await session.command.result()
            print("Driver acceptance \(layout.profile.revision.rawValue) AppID=\(appID): \(result.stdoutText)")
            _ = try await session.stop()
            #expect(try await session.snapshot().processes.isEmpty)
            try #require(result.termination == .exited(0), "\(result.stderrText)")
        }
        do {
            let driver = try await select(.driverVersion1)
            let enabled = try GameCompatibilityPreferences.read(root: store.root).driverEnabled(appID: 553850, revision: driver.profile.revision)
            try await inspect(driver, appID: 553850, expected: enabled ? "substituted" : "baseline")
            try await inspect(driver, appID: 999998, expected: "baseline")
            let rollback = try await select(.textInput1, bundle: old.bundle)
            try await inspect(rollback, appID: 553850, expected: "baseline")
            _ = try await select(.driverVersion1)
            print("Driver revision selected; real query, other-loader control, rollback, and unchanged prefix DLL/registry at selection verified")
        } catch {
            try await settings.select(old.bundle, revision: old.profile.revision, graphicsBackend: old.graphicsBackend)
            throw error
        }
    }
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
