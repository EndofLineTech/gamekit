import Foundation
import Testing
@testable import GamekitCore

private final class DiagnosticClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date = Date(timeIntervalSince1970: 1_700_000_000)
    func now() -> Date { lock.lock(); defer { lock.unlock() }; return date }
    func advance(_ interval: TimeInterval) { lock.lock(); date.addTimeInterval(interval); lock.unlock() }
}

private struct DiagnosticFixture {
    let parent: URL
    let base: URL
    init() throws {
        parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        base = parent.appendingPathComponent("GamekitLogs")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    }
    func remove() { try? FileManager.default.removeItem(at: parent) }
}

@Suite("Local diagnostics and safe exports")
struct DiagnosticsTests {
    @Test("Output capture is bounded but continues counting and detecting split signatures")
    func boundedCapture() async throws {
        let fixture = try DiagnosticFixture(); defer { fixture.remove() }
        let store = try DiagnosticStore(base: fixture.base, policy: .init(bytesPerStream: 8))
        let operation = try await store.begin(stage: .rendering)
        operation.receive(.init(channel: .stdout, bytes: Data("1234567890123456".utf8)))
        operation.receive(.init(channel: .stderr, bytes: Data("wine: Unhandled pa".utf8)))
        operation.receive(.init(channel: .stderr, bytes: Data("ge fault on read access\n".utf8)))
        let summary = try await store.finish(operation, outcome: .exited(0))
        let output = try await store.localOutput(summary.id)
        #expect(output.stdout.count == 8 && output.stderr.count == 8)
        #expect(summary.stdoutBytes == 16 && summary.stderrBytes > 8)
        #expect(summary.outputTruncated)
        #expect(summary.signature?.signature == .unhandledException)
        #expect(summary.category == .rendering)
    }

    @Test("Export excludes arbitrary credentials and session data rather than relying on regex guesses")
    func exportPrivacy() async throws {
        let fixture = try DiagnosticFixture(); defer { fixture.remove() }
        let store = try DiagnosticStore(base: fixture.base)
        let privateID = try EnvironmentID("private-account")
        let operation = try await store.begin(stage: .bootstrap, context: .init(
            environmentID: privateID,
            runtimeSelection: RuntimeIdentity(provider: "OPAQUE_CONTEXT_SECRET", distribution: "1", wine: "1", graphics: "1")
        ))
        operation.receive(.init(channel: .stdout, bytes: Data("Authorization: Bearer SPLIT_".utf8)))
        operation.receive(.init(channel: .stdout, bytes: Data("TOKEN\nuser=person@example.com\npassword=hunter-example\ncookie=session=abc\nOpaqueSecretWithoutLabel\n/Users/private/home\nSteamGuard=123456\n".utf8)))
        _ = try await store.finish(operation, outcome: .exited(7))
        let sessionFile = fixture.base.appendingPathComponent("Operations/loginusers.vdf")
        try Data("UNRELATED_SESSION_FILE_SECRET".utf8).write(to: sessionFile)
        let data = try await store.exportSummary(operation.id)
        let text = String(decoding: data, as: UTF8.self)
        for secret in ["SPLIT_TOKEN", "person@example.com", "hunter-example", "session=abc", "OpaqueSecretWithoutLabel", "/Users/private", "123456", "private-account", "OPAQUE_CONTEXT_SECRET", "UNRELATED_SESSION_FILE_SECRET"] {
            #expect(!text.contains(secret))
        }
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["stdout"] == nil && object["stderr"] == nil && object["context"] == nil)
        let allowed: Set<String> = ["schemaVersion", "id", "startedAt", "updatedAt", "elapsedSeconds", "stage", "component",
                                   "appVersion", "operatingSystem", "recognizedRuntimeSelection", "outcome", "commandTermination",
                                   "commandDurationSeconds", "category", "signature", "events", "eventsDropped", "stdoutBytes",
                                   "stderrBytes", "outputTruncated", "outputIncomplete", "checkpointFailed", "recommendation"]
        #expect(Set(object.keys).isSubset(of: allowed))
        #expect(text.contains("bootstrap"))
        #expect(String(decoding: try await store.localOutput(operation.id).stdout, as: UTF8.self).contains("SPLIT_TOKEN"))
    }

    @Test("Stage history is bounded and classification follows the failing operation")
    func stageHistory() async throws {
        let fixture = try DiagnosticFixture(); defer { fixture.remove() }
        let store = try DiagnosticStore(base: fixture.base, policy: .init(maximumStageEvents: 3))
        let operation = try await store.begin(stage: .download)
        try await store.transition(operation, to: .installation)
        try await store.transition(operation, to: .bootstrap)
        try await store.transition(operation, to: .rendering)
        let summary = try await store.finish(operation, outcome: .exited(23))
        #expect(summary.events.count == 3 && summary.eventsDropped == 1)
        #expect(summary.events.first?.stage == .download)
        #expect(summary.events.last?.stage == .rendering)
        #expect(summary.category == .rendering)
        #expect(summary.elapsedSeconds >= 0)
    }

    @Test("Retention evicts old completed records but preserves active operations")
    func retention() async throws {
        let fixture = try DiagnosticFixture(); defer { fixture.remove() }
        let clock = DiagnosticClock()
        let store = try DiagnosticStore(base: fixture.base, policy: .init(maximumOperations: 2, maximumAge: 60), clock: { clock.now() })
        let active = try await store.begin(stage: .bootstrap)
        clock.advance(1)
        let old = try await store.begin(stage: .download)
        _ = try await store.finish(old, outcome: .exited(0))
        clock.advance(1)
        let newest = try await store.begin(stage: .installation)
        #expect(try await store.summaries().map(\.id).contains(active.id))
        #expect(!(try await store.summaries().map(\.id).contains(old.id)))
        await #expect(throws: DiagnosticStoreError.capacityReached) { try await store.begin(stage: .launch) }
        _ = try await store.finish(active, outcome: .cancelled)
        _ = try await store.finish(newest, outcome: .exited(0))
        clock.advance(61)
        #expect(try await store.summaries().isEmpty)
    }

    @Test("Another store cannot prune a live operation's record")
    func activeAcrossStores() async throws {
        let fixture = try DiagnosticFixture(); defer { fixture.remove() }
        let first = try DiagnosticStore(base: fixture.base, policy: .init(maximumOperations: 1))
        let second = try DiagnosticStore(base: fixture.base, policy: .init(maximumOperations: 1))
        let operation = try await first.begin(stage: .runtimeProbe)
        await #expect(throws: DiagnosticStoreError.capacityReached) { try await second.begin(stage: .runtimeProbe) }
        #expect(try await second.summaries().map(\.id) == [operation.id])
        _ = try await first.finish(operation, outcome: .exited(0))
    }

    @Test("Checkpointed unfinished records survive reopening without being labeled successful")
    func unfinishedRecord() async throws {
        let fixture = try DiagnosticFixture(); defer { fixture.remove() }
        var store: DiagnosticStore? = try DiagnosticStore(base: fixture.base)
        let operation = try #require(await store?.begin(stage: .installation))
        operation.receive(.init(channel: .stderr, bytes: Data("installer started".utf8)))
        try await store?.checkpoint(operation)
        store = nil
        let reopened = try DiagnosticStore(base: fixture.base)
        let summary = try #require(await reopened.summaries().first)
        #expect(summary.category == .incomplete)
        #expect(try await reopened.localOutput(summary.id).stderr == Data("installer started".utf8))
    }

    @Test("A deliberately failing real command produces an actionable classified record")
    func realCommandFailure() async throws {
        let fixture = try DiagnosticFixture(); defer { fixture.remove() }
        let store = try DiagnosticStore(base: fixture.base)
        let execution = await DiagnosticCommandRunner(store: store).run(
            CommandRequest(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "printf 'DLL initialization failed error=1114\\n' >&2; exit 23"]),
            stage: .bootstrap
        )
        #expect(execution.command?.termination == .exited(23))
        #expect(execution.storageIssue == nil)
        #expect(execution.summary?.category == .bootstrap)
        #expect(execution.summary?.signature?.signature == .dllInitialization)
        #expect(execution.summary?.recommendation.contains("runtime") == true)
        #expect(execution.summary?.commandTermination == .exited(23))
        #expect((execution.summary?.commandDurationSeconds ?? -1) >= 0)
    }

    @Test("Periodic checkpoints persist active output before finish")
    func periodicCheckpoint() async throws {
        let fixture = try DiagnosticFixture(); defer { fixture.remove() }
        let store = try DiagnosticStore(base: fixture.base, policy: .init(checkpointInterval: 0.05))
        let operation = try await store.begin(stage: .bootstrap)
        operation.receive(.init(channel: .stdout, bytes: Data("checkpoint marker".utf8)))
        let reader = try DiagnosticStore(base: fixture.base)
        var captured = Data()
        for _ in 0..<100 {
            captured = try await reader.localOutput(operation.id).stdout
            if !captured.isEmpty { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(captured == Data("checkpoint marker".utf8))
        // Listing also prunes under the catalog writer lock. Use the owner actor
        // to serialize that check with its timer; the independent reader above
        // already proves that the output reached disk before finish.
        #expect(try await store.summaries().first?.category == .incomplete)
        _ = try await store.finish(operation, outcome: .exited(0))
    }

    @Test("A temporarily unavailable directory is reported by the final checkpoint flag")
    func unavailableCheckpointDirectory() async throws {
        let fixture = try DiagnosticFixture(); defer { fixture.remove() }
        let store = try DiagnosticStore(base: fixture.base, policy: .init(checkpointInterval: 60))
        let operation = try await store.begin(stage: .bootstrap)
        let directory = fixture.base.appendingPathComponent("Operations")
        let displaced = fixture.parent.appendingPathComponent("displaced")
        try FileManager.default.moveItem(at: directory, to: displaced)
        await #expect(throws: DiagnosticStoreError.notFound) { try await store.checkpoint(operation) }
        try FileManager.default.moveItem(at: displaced, to: directory)
        let summary = try await store.finish(operation, outcome: .exited(0))
        #expect(summary.checkpointFailed)
        #expect(summary.category == .none)
    }

    @Test("Maximum stream capture remains below the atomic record-size ceiling")
    func recordSizeBound() async throws {
        let fixture = try DiagnosticFixture(); defer { fixture.remove() }
        let store = try DiagnosticStore(base: fixture.base)
        let operation = try await store.begin(stage: .runtimeProbe)
        operation.receive(.init(channel: .stdout, bytes: Data(repeating: 0, count: 524_288)))
        operation.receive(.init(channel: .stderr, bytes: Data(repeating: 0xff, count: 524_288)))
        let summary = try await store.finish(operation, outcome: .exited(0))
        #expect(summary.outputTruncated)
        let file = fixture.base.appendingPathComponent("Operations/\(operation.id.uuidString.lowercased()).json")
        #expect(try Data(contentsOf: file).count <= 1_048_576)
    }

    @Test("Managed orphan temporaries are removed; unknown files are preserved")
    func orphanCleanup() async throws {
        let fixture = try DiagnosticFixture(); defer { fixture.remove() }
        let directory = fixture.base.appendingPathComponent("Operations")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let orphan = directory.appendingPathComponent(".diagnostic-\(UUID().uuidString).tmp")
        let unknown = directory.appendingPathComponent("unrelated.tmp")
        try Data("partial".utf8).write(to: orphan)
        try Data("preserve".utf8).write(to: unknown)
        _ = try await DiagnosticStore(base: fixture.base).summaries()
        #expect(!FileManager.default.fileExists(atPath: orphan.path))
        #expect(try Data(contentsOf: unknown) == Data("preserve".utf8))
    }

    @Test("Corrupt owned records are surfaced and not swept by retention")
    func corruptRecord() async throws {
        let fixture = try DiagnosticFixture(); defer { fixture.remove() }
        let store = try DiagnosticStore(base: fixture.base)
        let operation = try await store.begin(stage: .runtimeProbe)
        _ = try await store.finish(operation, outcome: .exited(0))
        let file = fixture.base.appendingPathComponent("Operations/\(operation.id.uuidString.lowercased()).json")
        let bytes = Data("{invalid".utf8)
        try bytes.write(to: file)
        await #expect(throws: (any Error).self) { try await store.summaries() }
        await #expect(throws: (any Error).self) { try await store.exportSummary(operation.id) }
        #expect(try Data(contentsOf: file) == bytes)
    }

    @Test("Log-file symlinks cannot expose external output or be pruned")
    func symlinkRecord() async throws {
        let fixture = try DiagnosticFixture(); defer { fixture.remove() }
        let store = try DiagnosticStore(base: fixture.base)
        let operation = try await store.begin(stage: .runtimeProbe)
        _ = try await store.finish(operation, outcome: .exited(0))
        let file = fixture.base.appendingPathComponent("Operations/\(operation.id.uuidString.lowercased()).json")
        let external = fixture.parent.appendingPathComponent("external")
        try Data("EXTERNAL_SECRET".utf8).write(to: external)
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: external)
        await #expect(throws: EnvironmentStoreError.unsafePath) { try await store.exportSummary(operation.id) }
        await #expect(throws: EnvironmentStoreError.unsafePath) { try await store.summaries() }
        #expect(try Data(contentsOf: external) == Data("EXTERNAL_SECRET".utf8))
    }

    @Test("Signature detection does not join unrelated lines into a false missing-dispatcher diagnosis")
    func signatureContext() {
        #expect(DiagnosticOperation.signature(in: "__wine_unix_call_dispatcher is present\nmissing font") == nil)
        #expect(DiagnosticOperation.signature(in: "wine_unix_call_dispatcher=present") == nil)
        #expect(DiagnosticOperation.signature(in: "wine_unix_call_dispatcher=absent") == .missingUnixDispatcher)
    }

    @Test("Launch failure and timeout are recorded without raw exception text")
    func failureKinds() async throws {
        let fixture = try DiagnosticFixture(); defer { fixture.remove() }
        let store = try DiagnosticStore(base: fixture.base)
        let runner = DiagnosticCommandRunner(store: store)
        let missing = await runner.run(CommandRequest(executable: URL(fileURLWithPath: "/missing-gamekit-command")), stage: .runtimeProbe)
        #expect(missing.command == nil && missing.launchError != nil)
        #expect(missing.summary?.category == .runtime)
        let timed = await runner.run(CommandRequest(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["10"], timeout: 0.1), stage: .bootstrap)
        #expect(timed.summary?.category == .timedOut)
    }

    @Test("Recording failure does not masquerade as a command failure")
    func unavailableStorage() async throws {
        let fixture = try DiagnosticFixture(); defer { fixture.remove() }
        let outside = fixture.parent.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: fixture.base, withDestinationURL: outside)
        let store = try DiagnosticStore(base: fixture.base)
        let execution = await DiagnosticCommandRunner(store: store).run(CommandRequest(executable: URL(fileURLWithPath: "/usr/bin/true")), stage: .runtimeProbe)
        #expect(execution.command?.termination == .exited(0))
        #expect(execution.storageIssue != nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
    }

    @Test("Stage-based failure categories remain distinct", arguments: [DiagnosticStage.download, .installation, .bootstrap, .rendering, .runtimeProbe])
    func classification(stage: DiagnosticStage) async throws {
        let fixture = try DiagnosticFixture(); defer { fixture.remove() }
        let store = try DiagnosticStore(base: fixture.base)
        let operation = try await store.begin(stage: stage)
        let summary = try await store.finish(operation, outcome: .exited(1))
        #expect(summary.category == stage.failureCategory)
    }
}
