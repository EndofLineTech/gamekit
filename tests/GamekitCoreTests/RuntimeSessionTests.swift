import Foundation
import Testing
@testable import GamekitCore

private struct SessionFixture: Sendable {
    let parent: URL
    let store: EnvironmentStore
    let layout: RuntimeLayout
    let records: [EnvironmentRecord]

    static func make() async throws -> SessionFixture {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + " fixture with spaces")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let root = parent.appendingPathComponent("Gamekit")
        let layout = RuntimeLayout(dataRoot: root, profile: .init(identity: RuntimeProfile.sikarugir.identity,
                                    bundlePath: "Runtimes/fixture.app", wineVersionOutput: "fixture", hashes: [:]))
        try FileManager.default.createDirectory(at: layout.wine.deletingLastPathComponent(), withIntermediateDirectories: true)
        let source = parent.appendingPathComponent("fixture.c")
        try Data(#"""
        #include <stdio.h>
        #include <stdlib.h>
        #include <string.h>
        #include <unistd.h>
        #include <sys/types.h>
        int main(int argc, char **argv) {
            char stop[4096];
            const char *prefix = getenv("WINEPREFIX");
            if (!prefix) return 2;
            snprintf(stop, sizeof(stop), "%s/stop", prefix);
            if (argc > 1 && strcmp(argv[1], "-k") == 0) {
                FILE *f = fopen(stop, "w"); if (!f) return 3; fclose(f); return 0;
            }
            pid_t child = fork();
            if (child < 0) return 4;
            if (child == 0) {
                setsid(); close(0); close(1); close(2);
                for (int i=0; i<1500 && access(stop, F_OK)!=0; ++i) usleep(20000);
                _exit(0);
            }
            printf("child=%d\n", child);
            return 0;
        }
        """#.utf8).write(to: source)
        let compiled = try await ProcessExecutor().run(CommandRequest(executable: URL(fileURLWithPath: "/usr/bin/clang"),
                                                                       arguments: [source.path, "-o", layout.wine.path]))
        guard compiled.termination == .exited(0) else { throw CommandError.invalidRequest }
        try FileManager.default.copyItem(at: layout.wine, to: layout.wineserver)
        let store = try EnvironmentStore(root: root)
        var records: [EnvironmentRecord] = []
        for name in ["owned", "unrelated"] {
            let record = try await store.create(sampleEnvironment(name))
            try FileManager.default.createDirectory(at: store.prefixURL(for: record.id), withIntermediateDirectories: true)
            records.append(record)
        }
        return SessionFixture(parent: parent, store: store, layout: layout, records: records)
    }

    func remove() {
        // The fixture's detached children exit cooperatively; never signal an
        // observed PID. This also runs after a failing assertion/test.
        for record in records {
            try? Data().write(to: store.prefixURL(for: record.id).appendingPathComponent("stop"))
        }
        for _ in 0..<100 {
            let active = records.contains {
                !RuntimeProcessObserver().snapshot(record: $0, prefix: store.prefixURL(for: $0.id), layout: layout).processes.isEmpty
            }
            if !active { break }
            Thread.sleep(forTimeInterval: 0.02)
        }
        try? FileManager.default.removeItem(at: parent)
    }
}

@Suite("Managed Wine session ownership")
struct RuntimeSessionTests {
    @Test("Natural completion waits for the detached child, not just the leader")
    func naturalCompletion() async throws {
        let fixture = try await SessionFixture.make(); defer { fixture.remove() }
        let record = fixture.records[0]
        let session = try await RuntimeSession.startFixture(store: fixture.store, id: record.id, layout: fixture.layout, arguments: ["handoff"])
        #expect(await session.command.result().termination == .exited(0))
        #expect(await session.end == nil)
        #expect(try await session.snapshot().processes.count == 1)
        let waiting = Task { try await session.waitUntilStopped() }
        try Data().write(to: fixture.store.prefixURL(for: record.id).appendingPathComponent("stop"))
        #expect(try await waiting.value == .completed)
        #expect(await session.command.result().termination == .exited(0))
    }
    @Test("Cancelling a session wait cleans up detached work before returning")
    func taskCancellation() async throws {
        let fixture = try await SessionFixture.make(); defer { fixture.remove() }
        let session = try await RuntimeSession.startFixture(store: fixture.store, id: fixture.records[0].id,
                                                            layout: fixture.layout, arguments: ["handoff"])
        _ = await session.command.result()
        let waiter = Task { try await session.waitUntilStopped() }
        try await Task.sleep(for: .milliseconds(50))
        waiter.cancel()
        await #expect(throws: CancellationError.self) { try await waiter.value }
        #expect(await session.end == .cancelled)
        let after = RuntimeProcessObserver().snapshot(record: fixture.records[0],
                                                     prefix: fixture.store.prefixURL(for: fixture.records[0].id), layout: fixture.layout)
        #expect(after.complete && after.processes.isEmpty)
    }
    @Test("Detached child is identified after launcher exit and unrelated prefix survives stop")
    func handoffAndStop() async throws {
        let fixture = try await SessionFixture.make(); defer { fixture.remove() }
        let first = try await RuntimeSession.startFixture(store: fixture.store, id: fixture.records[0].id, layout: fixture.layout, arguments: ["handoff"])
        let second = try await RuntimeSession.startFixture(store: fixture.store, id: fixture.records[1].id, layout: fixture.layout, arguments: ["handoff"])
        #expect(await first.command.result().termination == .exited(0))
        #expect(await second.command.result().termination == .exited(0))
        let snapshot = try await first.snapshot()
        #expect(snapshot.complete)
        #expect(snapshot.processes.count == 1)
        #expect(snapshot.processes.allSatisfy { $0.identity.pid != first.command.pid && $0.sessionID == first.sessionID })
        _ = try await first.stop()
        #expect(try await first.snapshot().processes.isEmpty)
        #expect(try await second.snapshot().processes.count == 1)
        _ = try await second.stop()
    }

    @Test("Session timeout stops detached children through the prefix backend")
    func timeout() async throws {
        let fixture = try await SessionFixture.make(); defer { fixture.remove() }
        let session = try await RuntimeSession.startFixture(store: fixture.store, id: fixture.records[0].id,
                                                            layout: fixture.layout, arguments: ["handoff"], timeout: 0.2)
        for _ in 0..<100 {
            if await session.end != nil { break }
            try await Task.sleep(for: .milliseconds(30))
        }
        #expect(await session.end == .timedOut)
        #expect(try await session.snapshot().processes.isEmpty)
    }

    @Test("Execution lease rejects duplicate work and runtime selection changes")
    func exclusiveLease() async throws {
        let fixture = try await SessionFixture.make(); defer { fixture.remove() }
        let record = fixture.records[0]
        let session = try await RuntimeSession.startFixture(store: fixture.store, id: record.id, layout: fixture.layout, arguments: ["handoff"])
        await #expect(throws: EnvironmentStoreError.busy) {
            try await RuntimeSession.startFixture(store: fixture.store, id: record.id, layout: fixture.layout, arguments: ["handoff"])
        }
        var changed = record
        changed.runtime = nil
        await #expect(throws: EnvironmentStoreError.busy) { try await fixture.store.save(changed) }
        var installing = record
        installing.installation = .installing(.bootstrappingSteam)
        installing = try await fixture.store.save(installing)
        await #expect(throws: EnvironmentStoreError.busy) {
            try await fixture.store.reconcile(record.id, process: .idle, prerequisites: .ready,
                                               expectedRevision: installing.revision)
        }
        _ = try await session.stop()
    }

    @Test("A stale observation revision cannot overwrite newer installation progress")
    func staleObservation() async throws {
        let fixture = try await SessionFixture.make(); defer { fixture.remove() }
        let original = fixture.records[0]
        var changed = original
        changed.installation = .installing(.creatingPrefix)
        _ = try await fixture.store.save(changed)
        await #expect(throws: EnvironmentStoreError.conflict) {
            try await fixture.store.reconcile(original.id, process: .idle, prerequisites: .ready,
                                               expectedRevision: original.revision)
        }
    }

    @Test("Foreign session appearing in the same prefix prevents prefix-wide cleanup")
    func refusesForeignProcess() async throws {
        let fixture = try await SessionFixture.make(); defer { fixture.remove() }
        let record = fixture.records[0]
        let session = try await RuntimeSession.startFixture(store: fixture.store, id: record.id, layout: fixture.layout, arguments: ["handoff"])
        _ = await session.command.result()
        let foreign = try await ProcessExecutor().run(CommandRequest(executable: fixture.layout.wine, arguments: ["handoff"],
                                  environment: fixture.layout.environment(prefix: fixture.store.prefixURL(for: record.id), session: "foreign")))
        #expect(foreign.termination == .exited(0))
        await #expect(throws: RuntimeSessionError.prefixBusy) { try await session.stop() }
        #expect(!FileManager.default.fileExists(atPath: fixture.store.prefixURL(for: record.id).appendingPathComponent("stop").path))
        #expect(try await session.snapshot().processes.count == 2)
        try Data().write(to: fixture.store.prefixURL(for: record.id).appendingPathComponent("stop"))
        try await Task.sleep(for: .milliseconds(100))
        _ = try await session.stop()
    }

    @Test("Pinned prefix identity rejects replacement")
    func prefixReplacement() async throws {
        let fixture = try await SessionFixture.make(); defer { fixture.remove() }
        let id = fixture.records[0].id
        let lease = try await fixture.store.executionLease(for: id)
        let old = fixture.parent.appendingPathComponent("retained-prefix")
        try FileManager.default.moveItem(at: lease.prefix, to: old)
        try FileManager.default.createDirectory(at: lease.prefix, withIntermediateDirectories: true)
        #expect(throws: EnvironmentStoreError.unsafePath) { try lease.validate() }
    }
}
