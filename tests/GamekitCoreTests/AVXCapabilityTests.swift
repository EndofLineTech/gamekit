import Foundation
import Testing
@testable import GamekitCore

@Suite("Opt-in Windows AVX capability comparison")
struct AVXCapabilityTests {
    @Test("Inspect the current DXGI adapter's reported driver version",
          .enabled(if: ProcessInfo.processInfo.environment["GAMEKIT_DXGI_PROBE"] == "1"))
    func inspectAdapter() async throws {
        let executable = try #require(ProcessInfo.processInfo.environment["GAMEKIT_DXGI_PROBE_PATH"])
        let store = try EnvironmentStore()
        let layout = try await RuntimeSettingsStore(store: store).layout()
        let session = try await RuntimeSession.start(store: store, id: SteamInstallationRecipe.environmentID,
            layout: layout, arguments: [executable], timeout: 60)
        do {
            let result = await session.command.result()
            print(result.stdoutText)
            #expect(result.termination == .exited(0))
            #expect(result.stdoutText.contains("PASS device/queue probe"))
            _ = try await session.stop()
            #expect(try await session.snapshot().processes.isEmpty)
        } catch { _ = try await session.stop(); throw error }
    }

    @Test("Compare advertisement and execution in separate disposable prefixes",
          .enabled(if: ProcessInfo.processInfo.environment["GAMEKIT_AVX_PROBE"] == "1"))
    func compare() async throws {
        let executable = try #require(ProcessInfo.processInfo.environment["GAMEKIT_AVX_PROBE_PATH"])
        let selected = try await RuntimeSettingsStore(store: EnvironmentStore()).layout()
        let report = try await RuntimeDetector().detect(selected, selection: selected.profile.identity)
        try #require(report.prerequisites == .ready)
        for advertised in [false, true] {
            let parent = try ManagedDirectory.canonicalRoot(FileManager.default.temporaryDirectory.appendingPathComponent("Gamekit AVX " + UUID().uuidString))
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let store = try EnvironmentStore(root: parent.appendingPathComponent("Gamekit"))
            let layout = RuntimeLayout(dataRoot: store.root, profile: selected.profile, bundle: selected.bundle,
                graphicsBackend: selected.graphicsBackend)
            let id = try EnvironmentID("avx-probe")
            let record = try await store.create(EnvironmentRecord(id: id, name: "Disposable AVX probe", runtime: layout.profile.identity,
                installation: .installing(.creatingPrefix)))
            let prefix = store.prefixURL(for: id)
            try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: true)
            let lease = try await store.executionLease(for: id)
            let token = UUID().uuidString
            var environment = layout.environment(prefix: prefix, session: token)
            environment["ROSETTA_ADVERTISE_AVX"] = advertised ? "1" : "0"
            let probeEnvironment = environment
            @Sendable func observed() async throws -> RuntimeProcessSnapshot {
                try lease.validate()
                let snapshot = await RuntimeProcessObserver().inspect(record: record, prefix: prefix, layout: layout)
                guard snapshot.complete else { throw RuntimeSessionError.observationUnavailable }
                guard snapshot.processes.allSatisfy({ $0.sessionID == token }) else { throw RuntimeSessionError.prefixBusy }
                return snapshot
            }
            func cleanup() async throws {
                _ = try await observed()
                let result = try await ProcessExecutor().run(.init(executable: layout.wineserver, arguments: ["-k"],
                    environment: probeEnvironment, workingDirectory: prefix, timeout: 10, outputLimit: 4096))
                try #require(result.termination == .exited(0) || result.termination == .exited(1))
                try await ScopedProcessTermination.finish { try await observed().processes }
            }
            do {
                let result = try await ProcessExecutor().run(.init(executable: layout.wine, arguments: [executable, "--execute"],
                    environment: probeEnvironment, workingDirectory: prefix, timeout: 90, outputLimit: 16384))
                print("Windows AVX advertisement=\(advertised): \(result.termination)")
                print(result.stdoutText)
                #expect(result.termination == .exited(0))
                #expect(result.stdoutText.contains("AVX execution: PASS") && result.stdoutText.contains("AVX2 execution: PASS"))
                if advertised {
                    #expect(result.stdoutText.contains("XSAVE=1 OSXSAVE=1 AVX=1"))
                    #expect(result.stdoutText.contains("AVX2=1 AVX512F=0"))
                    #expect(result.stdoutText.contains("XMM/YMM enabled=1"))
                    #expect(result.stdoutText.contains("Windows PF: XSAVE=1 AVX=1 AVX2=1 AVX512F=0"))
                } else {
                    #expect(result.stdoutText.contains("XSAVE=0 OSXSAVE=0 AVX=0"))
                }
                try await cleanup()
                withExtendedLifetime(lease) {}
                try FileManager.default.removeItem(at: parent)
            } catch {
                try await cleanup()
                throw error
            }
        }
    }
}
