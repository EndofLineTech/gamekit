import Foundation
import Testing
@testable import GamekitCore

@Suite("Opt-in bounded GPU timestamp query observation")
struct TimestampQueryTests {
    @Test("Compare timestamp readback in disposable Metal3 and automatic prefixes",
          .enabled(if: ProcessInfo.processInfo.environment["GAMEKIT_TIMESTAMP_PROBE"] == "1"))
    func compare() async throws {
        let executable = try #require(ProcessInfo.processInfo.environment["GAMEKIT_TIMESTAMP_PROBE_PATH"])
        let selected = try await RuntimeSettingsStore(store: EnvironmentStore()).layout()
        for backend in [D3DMetalBackend.metal3, .automatic] {
            let parent = try ManagedDirectory.canonicalRoot(FileManager.default.temporaryDirectory.appendingPathComponent("Gamekit Timestamp " + UUID().uuidString))
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let store = try EnvironmentStore(root: parent.appendingPathComponent("Gamekit"))
            let layout = RuntimeLayout(dataRoot: store.root, profile: selected.profile, bundle: selected.bundle, graphicsBackend: backend)
            let id = try EnvironmentID("timestamp-probe")
            _ = try await store.create(.init(id: id, name: "Disposable timestamp probe", runtime: layout.profile.identity,
                installation: .installing(.creatingPrefix)))
            try FileManager.default.createDirectory(at: store.prefixURL(for: id), withIntermediateDirectories: true)
            let session = try await RuntimeSession.start(store: store, id: id, layout: layout, arguments: [executable], timeout: 120)
            do {
                let result = await session.command.result()
                print("Timestamp backend=\(backend.rawValue): \(result.termination)\n\(result.stdoutText)")
                try #require([.exited(0), .exited(2)].contains(result.termination))
                #expect(result.stdoutText.contains("round=2 copy_valid=1"))
                #expect(result.stdoutText.contains("PASS timestamps") || result.stdoutText.contains("OBSERVED timestamps unavailable"))
                _ = try await session.stop()
                #expect(try await session.snapshot().processes.isEmpty)
                try FileManager.default.removeItem(at: parent)
            } catch { _ = try await session.stop(); throw error }
        }
    }
}
