import Foundation
import Testing
@testable import GamekitCore

private let registryFixture = """
WINE REGISTRY Version 2
;; All keys relative to REGISTRY\\\\User\\\\fixture

#arch=win64

[Software\\\\Wine\\\\Mac Driver] 1
"CaptureDisplaysForFullscreen"="y"

[Software\\\\Wine\\\\AppDefaults\\\\helldivers2.exe\\\\Mac Driver] 1
"OtherSetting"="keep"
"CaptureDisplaysForFullscreen"="n"

[Software\\\\Other] 1
"CaptureDisplaysForFullscreen"="unrelated"

"""

private struct CompatibilityFixture {
    let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store: EnvironmentStore
    let prefix: URL
    init() async throws {
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        store = try EnvironmentStore(root: parent.appendingPathComponent("Gamekit"))
        let id = SteamInstallationRecipe.environmentID
        _ = try await store.create(.init(id: id, name: "Steam", runtime: RuntimeProfile.sikarugir.identity, installation: .installed, installationRecipeVersion: 1))
        prefix = store.prefixURL(for: id)
        let steam = prefix.appendingPathComponent("drive_c/Program Files (x86)/Steam")
        try FileManager.default.createDirectory(at: steam.appendingPathComponent("steamapps/common/Helldivers"), withIntermediateDirectories: true)
        try Data("fixture".utf8).write(to: steam.appendingPathComponent("Steam.exe"))
        try Data(#""AppState" { "appid" "553850" "name" "Helldivers" "installdir" "Helldivers" "StateFlags" "4" }"#.utf8).write(to: steam.appendingPathComponent("steamapps/appmanifest_553850.acf"))
        try Data(registryFixture.utf8).write(to: prefix.appendingPathComponent("user.reg"))
    }
    func remove() { try? FileManager.default.removeItem(at: parent) }
    func settings(complete: Bool = true, running: Bool = false) -> GameCompatibilityStore {
        GameCompatibilityStore(store: store, observe: { _, _, _ in
            .init(processes: running ? [.init(identity: .init(pid: 123, startSeconds: 1, startMicroseconds: 0), role: .other, sessionID: nil)] : [], complete: complete)
        })
    }
}

@Suite("Per-game compatibility settings")
struct GameCompatibilityTests {
    @Test("Unavailable payloads cannot change a saved backend or driver preference")
    func missingGraphicsPayload() async throws {
        let fixture = try await CompatibilityFixture(); defer { fixture.remove() }
        let settings = fixture.settings()
        for choice in [GameGraphicsOverride.dxmt, .dxvk] {
            await #expect(throws: GraphicsPayloadError.unavailable) { try await settings.setGraphicsBackend(choice, appID: 553850) }
            #expect(try await settings.inspectGraphics(appID: 553850).override == .inherit)
        }
        #expect(try Data(contentsOf: fixture.prefix.appendingPathComponent("user.reg")) == Data(registryFixture.utf8))
        #expect(GameGraphicsOverride.dxmt.effectiveBackend(shared: .metal3) == .dxmt)
        #expect(GameGraphicsOverride.inherit.effectiveBackend(shared: .dxvk) == .dxvk)
        let layout = RuntimeLayout(dataRoot: fixture.store.root, graphicsBackend: .dxmt)
        #expect(layout.environment()["D3DM_MTL4"] == "0", "Steam retains Metal3 when the shared game default is DXMT")
    }
    @Test("Backend overrides are per installed game, preserve shared selection and migrate driver preferences")
    func graphicsOverrides() async throws {
        let fixture = try await CompatibilityFixture(); defer { fixture.remove() }
        let apps = fixture.prefix.appendingPathComponent("drive_c/Program Files (x86)/Steam/steamapps")
        try FileManager.default.createDirectory(at: apps.appendingPathComponent("common/Another Game"), withIntermediateDirectories: true)
        try Data(#""AppState" { "appid" "123456" "name" "Another Game" "installdir" "Another Game" "StateFlags" "4" }"#.utf8).write(to: apps.appendingPathComponent("appmanifest_123456.acf"))
        let runtime = RuntimeSettingsStore(store: fixture.store)
        try await runtime.select(nil, revision: .driverVersion1, graphicsBackend: .metal3)
        let selected = try Data(contentsOf: fixture.store.root.appendingPathComponent("Metadata/RuntimeSelection.json"))
        let preferences = fixture.store.root.appendingPathComponent("Metadata/GameCompatibility.json")
        try Data(#"{"schemaVersion":1,"driverVersions":{"553850":false}}"#.utf8).write(to: preferences)
        let settings = fixture.settings()
        let inherited = try await settings.inspectGraphics(appID: 123456)
        #expect(inherited.override == .inherit && inherited.effectiveBackend == .metal3)
        let automatic = try await settings.setGraphicsBackend(.automatic, appID: 123456)
        #expect(automatic.override == .automatic && automatic.effectiveBackend == .automatic)
        #expect(try await settings.inspectGraphics(appID: 553850).override == .inherit)
        #expect(try await settings.inspect(appID: 553850).driverCompatibility == false)
        #expect(try await fixture.settings().inspectGraphics(appID: 123456).override == .automatic)
        #expect(try Data(contentsOf: fixture.store.root.appendingPathComponent("Metadata/RuntimeSelection.json")) == selected)
        #expect(try Data(contentsOf: fixture.prefix.appendingPathComponent("user.reg")) == Data(registryFixture.utf8))
        let restored = try await settings.setGraphicsBackend(.inherit, appID: 123456)
        #expect(restored.effectiveBackend == .metal3)
        try await runtime.selectGraphicsBackend(.automatic)
        #expect(try await settings.inspectGraphics(appID: 123456).effectiveBackend == .automatic)
        #expect(try await settings.setGraphicsBackend(.metal3, appID: 553850).effectiveBackend == .metal3)
    }

    @Test("Backend choices reject active/uncertain sessions, absent games and unsupported values")
    func graphicsGuards() async throws {
        let fixture = try await CompatibilityFixture(); defer { fixture.remove() }
        await #expect(throws: SteamRecoveryError.activeProcesses) { try await fixture.settings(running: true).setGraphicsBackend(.automatic, appID: 553850) }
        await #expect(throws: SteamRecoveryError.observationUnavailable) { try await fixture.settings(complete: false).setGraphicsBackend(.automatic, appID: 553850) }
        await #expect(throws: SteamGameLibraryError.notInstalled) { try await fixture.settings().setGraphicsBackend(.metal3, appID: 999) }
        let file = fixture.store.root.appendingPathComponent("Metadata/GameCompatibility.json")
        for invalid in [#"{"schemaVersion":2,"driverVersions":{},"graphicsBackends":{"553850":"unknown"}}"#,
                        #"{"schemaVersion":2,"driverVersions":{},"graphicsBackends":null}"#,
                        #"{"schemaVersion":2,"driverVersions":{},"graphicsBackends":{"0553850":"metal3"}}"#,
                        #"{"schemaVersion":1,"driverVersions":{},"graphicsBackends":{"553850":"metal3"}}"#] {
            try Data(invalid.utf8).write(to: file)
            await #expect(throws: (any Error).self) { try await fixture.settings().setGraphicsBackend(.inherit, appID: 553850) }
            #expect(try String(contentsOf: file, encoding: .utf8) == invalid)
        }
    }
    @Test("Per-game driver toggle changes the real query and restores the user's choice",
          .enabled(if: ProcessInfo.processInfo.environment["GAMEKIT_GAME_DRIVER_ACCEPTANCE"] == "1"))
    func liveDriverPreference() async throws {
        let probe = try #require(ProcessInfo.processInfo.environment["GAMEKIT_DRIVER_PROBE_PATH"])
        let store = try EnvironmentStore()
        let layout = try await RuntimeSettingsStore(store: store).layout()
        try #require(layout.profile.revision == .driverVersion1)
        let settings = GameCompatibilityStore(store: store)
        let initial = try await settings.inspect(appID: 553850)
        let selection = try Data(contentsOf: store.root.appendingPathComponent("Metadata/RuntimeSelection.json"))
        let prefixDLL = store.prefixURL(for: SteamInstallationRecipe.environmentID).appendingPathComponent("drive_c/windows/system32/dxgi.dll")
        let dll = try Data(contentsOf: prefixDLL)
        do {
            for enabled in [false, true] {
                let saved = try await settings.setDriverCompatibility(enabled, appID: 553850)
                #expect(saved.driverCompatibility == enabled)
                let session = try await RuntimeSession.startGameProbe(store: store, id: SteamInstallationRecipe.environmentID,
                    layout: layout, game: .init(appID: 553850, name: "HELLDIVERS™ 2"), arguments: [probe, enabled ? "substituted" : "baseline"])
                let result = await session.command.result()
                print("Per-game driver enabled=\(enabled): \(result.stdoutText)")
                _ = try await session.stop()
                try #require(result.termination == .exited(0), "\(result.stderrText)")
                #expect(try Data(contentsOf: prefixDLL) == dll)
                #expect(try Data(contentsOf: store.root.appendingPathComponent("Metadata/RuntimeSelection.json")) == selection)
            }
        } catch {
            _ = try await settings.setDriverCompatibility(initial.driverCompatibility, appID: 553850)
            throw error
        }
        _ = try await settings.setDriverCompatibility(initial.driverCompatibility, appID: 553850)
    }
    @Test("Driver compatibility is a saved per-game choice independent of runtime selection")
    func driverPreference() async throws {
        let fixture = try await CompatibilityFixture(); defer { fixture.remove() }
        let runtime = RuntimeSettingsStore(store: fixture.store)
        try await runtime.select(nil, revision: .driverVersion1, graphicsBackend: .metal3)
        let selection = try Data(contentsOf: fixture.store.root.appendingPathComponent("Metadata/RuntimeSelection.json"))
        let settings = fixture.settings()
        let initial = try await settings.inspect(appID: 553850)
        #expect(initial.driverCompatibilityAvailable && initial.driverCompatibility)
        let disabled = try await settings.setDriverCompatibility(false, appID: 553850)
        #expect(!disabled.driverCompatibility)
        #expect(try await fixture.settings().inspect(appID: 553850).driverCompatibility == false)
        #expect(try Data(contentsOf: fixture.store.root.appendingPathComponent("Metadata/RuntimeSelection.json")) == selection)
        #expect(try Data(contentsOf: fixture.prefix.appendingPathComponent("user.reg")) == Data(registryFixture.utf8))
        _ = try await settings.setFullscreenSpace(true, appID: 553850)
        let enabled = try await settings.setDriverCompatibility(true, appID: 553850)
        #expect(enabled.driverCompatibility && enabled.fullscreenSpace && enabled.capture == .disabled)
    }

    @Test("Driver preference refuses active sessions, unsupported games and unsupported runtimes")
    func driverPreferenceGuards() async throws {
        let fixture = try await CompatibilityFixture(); defer { fixture.remove() }
        await #expect(throws: GameCompatibilityError.driverRuntimeRequired) {
            try await fixture.settings().setDriverCompatibility(true, appID: 553850)
        }
        try await RuntimeSettingsStore(store: fixture.store).select(nil, revision: .driverVersion1)
        await #expect(throws: SteamRecoveryError.activeProcesses) { try await fixture.settings(running: true).setDriverCompatibility(false, appID: 553850) }
        await #expect(throws: SteamRecoveryError.observationUnavailable) { try await fixture.settings(complete: false).setDriverCompatibility(false, appID: 553850) }
        await #expect(throws: GameCompatibilityError.unsupportedGame) { try await fixture.settings().setDriverCompatibility(true, appID: 413150) }
        let preferences = fixture.store.root.appendingPathComponent("Metadata/GameCompatibility.json")
        for invalid in [#"{"schemaVersion":9,"driverVersions":{}}"#, #"{"schemaVersion":1,"driverVersions":{"553850":1}}"#, #"{"schemaVersion":1,"driverVersions":{"413150":true}}"#] {
            try Data(invalid.utf8).write(to: preferences)
            await #expect(throws: (any Error).self) { try await fixture.settings().setDriverCompatibility(false, appID: 553850) }
            #expect(try String(contentsOf: preferences, encoding: .utf8) == invalid)
        }
    }
    @Test("Explicit live fullscreen Space selection through the product store", .enabled(if: ProcessInfo.processInfo.environment["GAMEKIT_SPACE_SETTING"] != nil))
    func liveSpaceSetting() async throws {
        let requested = try #require(ProcessInfo.processInfo.environment["GAMEKIT_SPACE_SETTING"])
        try #require(["enabled", "disabled"].contains(requested))
        let store = try EnvironmentStore()
        let result = try await GameCompatibilityStore(store: store).setFullscreenSpace(requested == "enabled", appID: 553850)
        #expect(result.fullscreenSpace == (requested == "enabled"))
        print("Saved Helldivers fullscreen Space: \(result.fullscreenSpace); capture: \(result.capture.rawValue); graphics: \(result.graphicsBackend.rawValue)")
    }

    @Test("Fullscreen Space is an opt-in saved separately from the accepted capture setting")
    func fullscreenSpacePreference() async throws {
        let fixture = try await CompatibilityFixture(); defer { fixture.remove() }
        let settings = fixture.settings()
        #expect(try await settings.inspect(appID: 553850).fullscreenSpace == false)
        let enabled = try await settings.setFullscreenSpace(true, appID: 553850)
        #expect(enabled.fullscreenSpace)
        #expect(try await fixture.settings().inspect(appID: 553850).fullscreenSpace)
        #expect(try Data(contentsOf: fixture.prefix.appendingPathComponent("user.reg")) == Data(registryFixture.utf8))
        let disabled = try await settings.setFullscreenSpace(false, appID: 553850)
        #expect(!disabled.fullscreenSpace)
        #expect(disabled.capture == .disabled)
        await #expect(throws: GameCompatibilityError.unsupportedGame) { try await settings.setFullscreenSpace(true, appID: 526870) }
    }

    @Test("Fullscreen Space changes require a stopped session and reject malformed settings")
    func fullscreenSpaceGuards() async throws {
        let fixture = try await CompatibilityFixture(); defer { fixture.remove() }
        await #expect(throws: SteamRecoveryError.activeProcesses) { try await fixture.settings(running: true).setFullscreenSpace(true, appID: 553850) }
        await #expect(throws: SteamRecoveryError.observationUnavailable) { try await fixture.settings(complete: false).setFullscreenSpace(true, appID: 553850) }
        let file = fixture.store.root.appendingPathComponent("Metadata/GamePresentation.json")
        for invalid in [#"{"schemaVersion":9,"fullscreenSpaces":{"553850":true}}"#, #"{"schemaVersion":1,"fullscreenSpaces":{"553850":1}}"#, #"{"schemaVersion":1,"fullscreenSpaces":{"413150":true}}"#] {
            try Data(invalid.utf8).write(to: file)
            await #expect(throws: (any Error).self) { try await fixture.settings().setFullscreenSpace(true, appID: 553850) }
            #expect(try String(contentsOf: file, encoding: .utf8) == invalid)
        }
    }

    @Test("Independent Windows registry queries observe saved choices after each fresh Wine session", .enabled(if: ProcessInfo.processInfo.environment["GAMEKIT_COMPATIBILITY_WINE_SMOKE"] == "1"))
    func wineReadback() async throws {
        let fixture = try await CompatibilityFixture(); defer { fixture.remove() }
        let selected = try await RuntimeSettingsStore(store: EnvironmentStore()).layout()
        let layout = RuntimeLayout(dataRoot: fixture.store.root, profile: selected.profile, bundle: selected.bundle, graphicsBackend: selected.graphicsBackend)
        let helper = try #require(ProcessInfo.processInfo.environment["GAMEKIT_CURSOR_PROBE_PATH"])
        func execute(_ arguments: [String]) async throws -> CommandResult {
            let session = try await RuntimeSession.start(store: fixture.store, id: SteamInstallationRecipe.environmentID,
                layout: layout, arguments: arguments, timeout: 120)
            let result = await session.command.result()
            _ = try await session.stop()
            try #require(result.termination == .exited(0))
            return result
        }
        _ = try await execute(SteamInstallationRecipe.initializeArguments)
        let settings = GameCompatibilityStore(store: fixture.store)
        for (value, expected) in [(GameCaptureOverride.enabled, "enabled"), (.disabled, "disabled"), (.inherit, "absent")] {
            _ = try await settings.setCapture(value, appID: 553850)
            let result = try await execute([helper, "query-display"])
            #expect(result.stdoutText.contains("display_capture=" + expected))
            #expect(try await settings.inspect(appID: 553850).capture == value)
            print("Disposable Wine registry readback: \(value.rawValue) -> \(expected)")
        }
    }

    @Test("Capture override persists, reads back and restores inheritance without touching siblings")
    func savedOverride() async throws {
        let fixture = try await CompatibilityFixture(); defer { fixture.remove() }
        let settings = fixture.settings()
        let initial = try await settings.inspect(appID: 553850)
        #expect(initial.capture == .disabled)
        #expect(initial.inheritedCapture)
        #expect(!initial.effectiveCapture)
        let enabled = try await settings.setCapture(.enabled, appID: 553850)
        #expect(enabled.effectiveCapture)
        #expect(try await fixture.settings().inspect(appID: 553850).capture == .enabled)
        let restored = try await settings.setCapture(.inherit, appID: 553850)
        #expect(restored.capture == .inherit && restored.effectiveCapture)
        let bytes = try String(contentsOf: fixture.prefix.appendingPathComponent("user.reg"), encoding: .utf8)
        #expect(bytes.contains("\"OtherSetting\"=\"keep\""))
        #expect(bytes.contains("\"CaptureDisplaysForFullscreen\"=\"unrelated\""))
        #expect(bytes == registryFixture.replacingOccurrences(of: "\"CaptureDisplaysForFullscreen\"=\"n\"\n", with: ""))
    }

    @Test("Missing app section can be created; Wine default capture is disabled")
    func newOverride() throws {
        let data = Data("WINE REGISTRY Version 2\n#arch=win64\n".utf8)
        let registry = try GameCaptureRegistry(data)
        #expect(try registry.capture == .inherit)
        #expect(try !registry.inheritedCapture)
        let enabled = try GameCaptureRegistry(registry.setting(.enabled))
        #expect(try enabled.capture == .enabled)
        let restored = try GameCaptureRegistry(enabled.setting(.inherit))
        #expect(try restored.capture == .inherit)
    }

    @Test("Ambiguous and unsupported registry values refuse edits", arguments: [
        registryFixture.replacingOccurrences(of: "\"n\"", with: "dword:00000001"),
        registryFixture + "[Software\\\\Wine\\\\AppDefaults\\\\helldivers2.exe\\\\Mac Driver]\n",
        registryFixture.replacingOccurrences(of: "\"n\"", with: "\"n\"\n\"CaptureDisplaysForFullscreen\"=\"y\""),
        "not a Wine registry"
    ])
    func malformedRegistry(text: String) {
        #expect(throws: (any Error).self) { _ = try GameCaptureRegistry(Data(text.utf8)).setting(.enabled) }
    }

    @Test("Live or incomplete observations block changes without altering registry bytes", arguments: [true, false])
    func processGuard(complete: Bool) async throws {
        let fixture = try await CompatibilityFixture(); defer { fixture.remove() }
        await #expect(throws: (any Error).self) { try await fixture.settings(complete: complete, running: complete).setCapture(.enabled, appID: 553850) }
        #expect(try Data(contentsOf: fixture.prefix.appendingPathComponent("user.reg")) == Data(registryFixture.utf8))
    }

    @Test("Unsupported games and saved sessions cannot be modified")
    func selectionGuard() async throws {
        let fixture = try await CompatibilityFixture(); defer { fixture.remove() }
        await #expect(throws: GameCompatibilityError.unsupportedGame) { try await fixture.settings().setCapture(.enabled, appID: 413150) }
        let lifecycle = fixture.store.root.appendingPathComponent("Metadata/Lifecycle")
        try FileManager.default.createDirectory(at: lifecycle, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: lifecycle.appendingPathComponent("steam.json"))
        await #expect(throws: EnvironmentStoreError.busy) { try await fixture.settings().setCapture(.enabled, appID: 553850) }
        await #expect(throws: EnvironmentStoreError.busy) { try await fixture.settings().setFullscreenSpace(true, appID: 553850) }
        await #expect(throws: EnvironmentStoreError.busy) { try await fixture.settings().setDriverCompatibility(false, appID: 553850) }
        await #expect(throws: EnvironmentStoreError.busy) { try await fixture.settings().setGraphicsBackend(.automatic, appID: 553850) }
        #expect(try Data(contentsOf: fixture.prefix.appendingPathComponent("user.reg")) == Data(registryFixture.utf8))
    }

    @Test("Registry symlinks and an active execution lease cannot redirect settings writes")
    func storageGuards() async throws {
        let fixture = try await CompatibilityFixture(); defer { fixture.remove() }
        let settings = fixture.settings()
        do {
            let lease = try await fixture.store.executionLease(for: SteamInstallationRecipe.environmentID)
            defer { withExtendedLifetime(lease) {} }
            await #expect(throws: EnvironmentStoreError.busy) { try await settings.setCapture(.enabled, appID: 553850) }
        }
        let registry = fixture.prefix.appendingPathComponent("user.reg")
        let outside = fixture.parent.appendingPathComponent("external.reg")
        try FileManager.default.moveItem(at: registry, to: outside)
        try FileManager.default.createSymbolicLink(at: registry, withDestinationURL: outside)
        await #expect(throws: (any Error).self) { try await settings.inspect(appID: 553850) }
        await #expect(throws: (any Error).self) { try await settings.setCapture(.enabled, appID: 553850) }
        #expect(try Data(contentsOf: outside) == Data(registryFixture.utf8))
    }
}
