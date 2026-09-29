import Foundation
import Testing
@testable import GamekitCore

/// Explicitly opt-in, disposable runtime acceptance. It never uses the
/// owner's registered environments or signs in to Ubisoft Connect.
@Suite("Isolated Ubisoft Connect runtime qualification")
struct UbisoftRuntimeQualificationTests {
    @Test("Install, observe, relaunch and stop only the disposable launcher prefix",
          .enabled(if: ProcessInfo.processInfo.environment["GAMEKIT_UBISOFT_QUALIFY"] == "1"))
    func installedClient() async throws {
        let env = ProcessInfo.processInfo.environment
        let installerPath = try #require(env["GAMEKIT_UBISOFT_INSTALLER_PATH"])
        let rootPath = try #require(env["GAMEKIT_UBISOFT_ROOT"])
        let bundlePath = try #require(env["GAMEKIT_UBISOFT_RUNTIME_BUNDLE"])
        let profile = try LauncherProfileStore.bundled("ubisoft")
        let root = URL(fileURLWithPath: rootPath)
        let store = try EnvironmentStore(root: root)
        let layout = RuntimeLayout(dataRoot: store.root, profile: .sikarugirDriverVersion1,
            bundle: URL(fileURLWithPath: bundlePath), graphicsBackend: .metal3)
        let data = try Data(contentsOf: URL(fileURLWithPath: installerPath))
        let acquisition = try ManagedLauncherInstallerAcquisition(profile: profile, root: store.root,
            transfer: { InstallerPayload(data: data, finalURL: profile.installer.url, status: 200, expectedBytes: Int64(data.count)) })
        let coordinator = try ManagedLauncherInstallationCoordinator(store: store, layout: layout, profile: profile,
            acquisition: acquisition)
        let installed = try await coordinator.install { stage in print("Ubisoft qualification stage: \(stage.rawValue)") }
        #expect(installed.installation == .installed)
        #expect(try await store.installationFiles(profile.id).executableExists)
        let lifecycle = try ManagedLauncherLifecycle(store: store, layout: layout, profile: profile)
        do {
            _ = try await lifecycle.launch()
            var readySince: ContinuousClock.Instant?
            var ready = false
            for _ in 0..<180 {
                let state = try await lifecycle.status()
                let snapshot = try? await lifecycle.diagnosticProcesses()
                if state == .running, snapshot?.complete == true,
                   snapshot?.processes.contains(where: { $0.role == .launcher }) == true,
                   snapshot?.processes.contains(where: { $0.role == .launcherUI }) == true {
                    if readySince == nil { readySince = .now }
                    if readySince!.duration(to: .now) >= .seconds(3) { ready = true; break }
                } else { readySince = nil }
                try await Task.sleep(for: .milliseconds(500))
            }
            #expect(ready, "Owned Ubisoft client and web helper must remain observable for three seconds")
            if ready { #expect(try await lifecycle.show() > 0) }
            #expect(try await lifecycle.stop() == .stopped)
            #expect(try await lifecycle.status() == .stopped)
        } catch {
            _ = try? await lifecycle.stop()
            throw error
        }
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("Metadata/Lifecycle/steam.json").path))
    }
}
