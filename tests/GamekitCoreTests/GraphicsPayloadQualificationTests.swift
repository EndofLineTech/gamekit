import Foundation
import Testing
@testable import GamekitCore

@Suite("Opt-in DXMT/DXVK payload qualification")
struct GraphicsPayloadQualificationTests {
    @Test("Derived loaders render both architectures while prefix and Steam graphics stay unchanged",
          .enabled(if: ProcessInfo.processInfo.environment["GAMEKIT_DERIVED_GRAPHICS_PROBE"] == "1"))
    func derivedLoaders() async throws {
        let env = ProcessInfo.processInfo.environment
        let helper = URL(fileURLWithPath: try #require(env["GAMEKIT_IDENTITY_X86_HELPER"]))
        let probes = [try #require(env["GAMEKIT_D3D11_PROBE"]), try #require(env["GAMEKIT_D3D11_PROBE32"])]
        let accepted = try await RuntimeSettingsStore(store: EnvironmentStore()).layout()
        let root = try ManagedDirectory.canonicalRoot(FileManager.default.temporaryDirectory.appendingPathComponent("Gamekit render " + UUID().uuidString))
        let store = try EnvironmentStore(root: root)
        let layout = RuntimeLayout(dataRoot: store.root, profile: accepted.profile, bundle: accepted.bundle, identityHelper: helper, graphicsBackend: .metal3)
        let id = SteamInstallationRecipe.environmentID
        _ = try await store.create(.init(id: id, name: "Render probe", runtime: layout.profile.identity, installation: .installed, installationRecipeVersion: 1))
        let prefix = store.prefixURL(for: id)
        try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: accepted.dataRoot.appendingPathComponent("GraphicsBackends"), to: root.appendingPathComponent("GraphicsBackends"))
        let settings = RuntimeSettingsStore(store: store)
        try await settings.select(accepted.bundle, revision: accepted.profile.revision, graphicsBackend: .metal3)
        let boot = try await RuntimeSession.start(store: store, id: id, layout: layout, arguments: SteamInstallationRecipe.initializeArguments, timeout: 120)
        let initialized = await boot.command.result(); _ = try await boot.stop()
        try #require(initialized.termination == .exited(0))
        let steam = prefix.appendingPathComponent(RelativePath.steamDefault.rawValue).deletingLastPathComponent()
        let apps = steam.appendingPathComponent("steamapps")
        let directory = apps.appendingPathComponent("common/Render Probe")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("fixture".utf8).write(to: steam.appendingPathComponent("Steam.exe"))
        try Data(#""AppState" { "appid" "900001" "name" "Render Probe" "installdir" "Render Probe" "StateFlags" "4" }"#.utf8).write(to: apps.appendingPathComponent("appmanifest_900001.acf"))
        let prefixDXGI = prefix.appendingPathComponent("drive_c/windows/system32/dxgi.dll")
        let original = try Data(contentsOf: prefixDXGI)
        let game = GameApplicationIdentity(appID: 900001, name: "Render Probe")
        let preferences = GameCompatibilityStore(store: store)
        for (index, probe) in probes.enumerated() {
            try FileManager.default.copyItem(at: URL(fileURLWithPath: probe), to: directory.appendingPathComponent("probe\(index).exe"))
        }
        for backend in [GameGraphicsOverride.dxmt, .dxvk, .metal3] {
            _ = try await preferences.setGraphicsBackend(backend, appID: game.appID)
            for index in probes.indices {
                if backend == .metal3 && index == 1 { continue } // Apple payload is x64 only.
                let session = try await RuntimeSession.startGameProbe(store: store, id: id, layout: layout, game: game,
                    arguments: [directory.appendingPathComponent("probe\(index).exe").path])
                let result = await session.command.result(); _ = try await session.stop()
                print("Derived \(backend.rawValue) arch=\(index == 0 ? "x64" : "x86"): \(result.termination)\n\(result.stdoutText)\n\(result.stderrText)")
                #expect(result.termination == .exited(0))
                #expect(result.stdoutText.contains("PASS D3D11 shader draw/readback/present"))
                #expect(try Data(contentsOf: prefixDXGI) == original)
                try SteamApplicationBundle(layout: layout).validate(layout.steamApplicationBundle)
            }
        }
        print("Disposable derived-loader evidence: \(root.path)")
    }
    @Test("Render using isolated candidate runtimes and fresh prefixes",
          .enabled(if: ProcessInfo.processInfo.environment["GAMEKIT_GRAPHICS_QUALIFICATION"] != nil))
    func render() async throws {
        let env = ProcessInfo.processInfo.environment
        let candidates = URL(fileURLWithPath: try #require(env["GAMEKIT_GRAPHICS_QUALIFICATION"]))
        let probe = try #require(env["GAMEKIT_D3D11_PROBE"])
        for backend in ["dxmt", "dxvk"] {
            let bundle = candidates.appendingPathComponent("\(backend)/Candidate.app")
            let replacements = try JSONDecoder().decode([String: String].self,
                from: Data(contentsOf: candidates.appendingPathComponent("\(backend)/qualification.json")))
            let accepted = RuntimeProfile.sikarugirDriverVersion1
            let profile = RuntimeProfile(identity: accepted.identity, bundlePath: accepted.bundlePath,
                wineVersionOutput: accepted.wineVersionOutput, hashes: accepted.hashes.merging(replacements) { _, new in new }, revision: accepted.revision)
            let root = try ManagedDirectory.canonicalRoot(candidates.appendingPathComponent("\(backend)/Probe-\(UUID().uuidString)"))
            let store = try EnvironmentStore(root: root)
            let layout = RuntimeLayout(dataRoot: store.root, profile: profile, bundle: bundle)
            let id = try EnvironmentID("graphics-probe")
            _ = try await store.create(.init(id: id, name: "Disposable graphics probe", runtime: profile.identity,
                installation: .installing(.creatingPrefix)))
            try FileManager.default.createDirectory(at: store.prefixURL(for: id), withIntermediateDirectories: true)
            let session = try await RuntimeSession.start(store: store, id: id, layout: layout, arguments: [probe], timeout: 120)
            let result = await session.command.result()
            print("Backend \(backend): \(result.termination)\n\(result.stdoutText)\n\(result.stderrText)")
            _ = try await session.stop()
            #expect(try await session.snapshot().processes.isEmpty)
            #expect(result.termination == .exited(0))
            #expect(result.stdoutText.contains("PASS D3D11 shader draw/readback/present"))
        }
    }
}
