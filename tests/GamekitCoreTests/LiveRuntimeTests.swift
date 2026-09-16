import Foundation
import Testing
@testable import GamekitCore

private final class SmokeOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = Data()
    func receive(_ output: CommandOutput) {
        guard output.channel == .stdout else { return }
        lock.lock(); defer { lock.unlock() }
        bytes.append(output.bytes.prefix(max(0, 1_048_576 - bytes.count)))
    }
    var sawMarker: Bool {
        lock.lock(); defer { lock.unlock() }
        return String(decoding: bytes, as: UTF8.self).contains("GAMEKIT_RUNTIME_SMOKE")
    }
}

@Suite("Opt-in installed runtime smoke test")
struct LiveRuntimeTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["GAMEKIT_RUNTIME_SMOKE"] == "1"))
    func installedRuntime() async throws {
        let layout = RuntimeLayout()
        let report = try await RuntimeDetector().detect(layout, selection: layout.profile.identity)
        #expect(report.prerequisites == .ready)
        guard report.prerequisites == .ready else { return }
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("Gamekit live smoke " + UUID().uuidString)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        // Only remove this fresh fixture after confirmed scope cleanup.
        let store = try EnvironmentStore(root: parent.appendingPathComponent("Gamekit"))
        var record = try await store.create(EnvironmentRecord(id: EnvironmentID("runtime-smoke"), name: "Runtime smoke",
                                                              runtime: layout.profile.identity))
        record.installation = .installing(.creatingPrefix)
        record = try await store.save(record)
        try FileManager.default.createDirectory(at: store.prefixURL(for: record.id), withIntermediateDirectories: true)
        let output = SmokeOutput()
        let session = try await RuntimeSession.start(store: store, id: record.id, layout: layout,
                                                      arguments: ["cmd", "/c", "echo", "GAMEKIT_RUNTIME_SMOKE"],
                                                      timeout: 60, onOutput: { output.receive($0) })
        do {
            for _ in 0..<400 {
                if output.sawMarker { break }
                try await Task.sleep(for: .milliseconds(50))
            }
            #expect(output.sawMarker)
            let processes = try await session.snapshot()
            #expect(processes.complete)
            #expect(!processes.processes.isEmpty)
            #expect(processes.processes.allSatisfy { $0.sessionID == session.sessionID })
            _ = try await session.stop()
            #expect(try await session.snapshot().processes.isEmpty)
            let after = RuntimeProcessObserver().snapshot(record: record, prefix: store.prefixURL(for: record.id), layout: layout)
            #expect(after.complete && after.processes.isEmpty)
            try FileManager.default.removeItem(at: parent)
        } catch {
            _ = try? await session.stop()
            throw error
        }
    }
}
