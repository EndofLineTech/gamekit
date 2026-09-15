import Foundation
import Testing
@testable import GamekitCore

private struct DiskFixture: Sendable {
    let parent: URL
    let root: URL
    let outside: URL

    init() throws {
        parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        root = parent.appendingPathComponent("Gamekit")
        outside = parent.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    }

    func remove() { try? FileManager.default.removeItem(at: parent) }
    func store() throws -> EnvironmentStore { try EnvironmentStore(root: root) }
    func metadata(_ id: String) -> URL { root.appendingPathComponent("Metadata/Environments/\(id).json") }
    func prefix(_ id: String) -> URL { root.appendingPathComponent("Environments/\(id)") }
    func put(_ text: String, at url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }
}

private enum SimulatedInterruption: Error { case beforeRename }

@Suite("Environment store on disk")
struct EnvironmentStoreTests {
    @Test("Initial publication failure leaves no registered environment")
    func interruptedCreate() async throws {
        let fixture = try DiskFixture()
        defer { fixture.remove() }
        let failing = try EnvironmentStore(root: fixture.root, beforeCommit: { throw SimulatedInterruption.beforeRename })
        await #expect(throws: SimulatedInterruption.self) { try await failing.create(sampleEnvironment()) }
        #expect(try await fixture.store().loadAll().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.prefix("steam-test").path))
    }

    @Test("Empty load is non-mutating; create/reopen preserves metadata and creates no prefix")
    func freshAndRoundTrip() async throws {
        let fixture = try DiskFixture()
        defer { fixture.remove() }
        let store = try fixture.store()
        #expect(try await store.loadAll().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.root.path))
        let record = try sampleEnvironment()
        let saved = try await store.create(record)
        #expect(try await fixture.store().load(record.id) == saved)
        #expect(!FileManager.default.fileExists(atPath: fixture.prefix(record.id.rawValue).path))
    }

    @Test("Real-time timestamp encoding remains usable for subsequent saves")
    func timestampRoundTrip() async throws {
        let fixture = try DiskFixture()
        defer { fixture.remove() }
        let store = try fixture.store()
        var record = try await store.create(EnvironmentRecord(id: EnvironmentID("timestamp-test"), name: "Steam"))
        record.name = "Updated"
        let saved = try await store.save(record)
        #expect(saved.createdAt == record.createdAt)
        #expect(try await fixture.store().load(record.id) == saved)
    }

    @Test("Interrupted atomic save preserves the old record and ignores orphan temporary files")
    func interruptedWrite() async throws {
        let fixture = try DiskFixture()
        defer { fixture.remove() }
        let original = try await fixture.store().create(sampleEnvironment())
        let before = try Data(contentsOf: fixture.metadata(original.id.rawValue))
        var update = original
        update.installation = .installing(.creatingPrefix)
        let failing = try EnvironmentStore(root: fixture.root, beforeCommit: { throw SimulatedInterruption.beforeRename })
        await #expect(throws: SimulatedInterruption.self) { try await failing.save(update) }
        #expect(try Data(contentsOf: fixture.metadata(original.id.rawValue)) == before)
        try fixture.put("partial garbage", at: fixture.root.appendingPathComponent("Metadata/Environments/.orphan.tmp"))
        #expect(try await fixture.store().loadAll() == [original])
    }

    @Test("Stale revisions and duplicate creation cannot overwrite newer records")
    func rejectsLostUpdates() async throws {
        let fixture = try DiskFixture()
        defer { fixture.remove() }
        let first = try await fixture.store().create(sampleEnvironment())
        var second = first
        second.name = "Updated Steam"
        let saved = try await fixture.store().save(second)
        #expect(saved.revision == first.revision + 1)
        await #expect(throws: EnvironmentStoreError.conflict) { try await fixture.store().save(first) }
        await #expect(throws: EnvironmentStoreError.alreadyExists) { try await fixture.store().create(first) }
        #expect(try await fixture.store().load(first.id) == saved)
    }

    @Test("Independent store actors cannot both commit the same revision")
    func concurrentWriters() async throws {
        let fixture = try DiskFixture()
        defer { fixture.remove() }
        let original = try await fixture.store().create(sampleEnvironment())
        let firstStore = try fixture.store()
        let secondStore = try fixture.store()
        func attempt(_ store: EnvironmentStore, name: String) async throws -> Bool {
            var record = original
            record.name = name
            do { _ = try await store.save(record); return true }
            catch EnvironmentStoreError.busy { return false }
            catch EnvironmentStoreError.conflict { return false }
        }
        async let first = attempt(firstStore, name: "First")
        async let second = attempt(secondStore, name: "Second")
        let results = try await [first, second]
        #expect(results.filter { $0 }.count == 1)
        let current = try #require(await fixture.store().load(original.id))
        #expect(current.revision == original.revision + 1)
        #expect(["First", "Second"].contains(current.name))
    }

    @Test("Descriptor-relative replacement never follows a destination swapped to an external symlink")
    func symlinkDuringCommit() async throws {
        let fixture = try DiskFixture()
        defer { fixture.remove() }
        var record = try await fixture.store().create(sampleEnvironment())
        let external = fixture.outside.appendingPathComponent("external.json")
        try fixture.put("external stays unchanged", at: external)
        let path = fixture.metadata(record.id.rawValue)
        let swapping = try EnvironmentStore(root: fixture.root, beforeCommit: {
            try FileManager.default.removeItem(at: path)
            try FileManager.default.createSymbolicLink(at: path, withDestinationURL: external)
        })
        record.name = "Safely replaced"
        let saved = try await swapping.save(record)
        #expect(try String(contentsOf: external, encoding: .utf8) == "external stays unchanged")
        #expect(try await fixture.store().load(record.id) == saved)
    }

    @Test("A directory swapped during commit cannot redirect the temporary file or rename")
    func directorySwapDuringCommit() async throws {
        let fixture = try DiskFixture()
        defer { fixture.remove() }
        var record = try await fixture.store().create(sampleEnvironment())
        let metadata = fixture.root.appendingPathComponent("Metadata/Environments")
        let retained = fixture.root.appendingPathComponent("RetainedMetadata")
        let swapping = try EnvironmentStore(root: fixture.root, beforeCommit: {
            try FileManager.default.moveItem(at: metadata, to: retained)
            try FileManager.default.createSymbolicLink(at: metadata, withDestinationURL: fixture.outside)
        })
        record.name = "Saved to pinned directory"
        let saved = try await swapping.save(record)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.outside.path).isEmpty)
        #expect(try EnvironmentDocument.decode(Data(contentsOf: retained.appendingPathComponent("steam-test.json"))) == saved)
        await #expect(throws: EnvironmentStoreError.unsafePath) { try await fixture.store().loadAll() }
    }

    @Test("Executable symlinks and symlinked executable parents are rejected", arguments: [false, true])
    func executableEscape(parentLink: Bool) async throws {
        let fixture = try DiskFixture()
        defer { fixture.remove() }
        let record = try await fixture.store().create(sampleEnvironment())
        let prefix = fixture.prefix(record.id.rawValue)
        let target = parentLink ? fixture.outside : fixture.outside.appendingPathComponent("Steam.exe")
        if !parentLink { try fixture.put("external executable", at: target) }
        let link = prefix.appendingPathComponent(parentLink ? "drive_c" : record.steamExecutable.rawValue)
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        await #expect(throws: EnvironmentStoreError.unsafePath) {
            try await fixture.store().reconcile(record.id, process: .idle, prerequisites: .ready)
        }
    }

    @Test("Oversized documents fail without mutation")
    func oversizedMetadata() async throws {
        let fixture = try DiskFixture()
        defer { fixture.remove() }
        let record = try await fixture.store().create(sampleEnvironment())
        let path = fixture.metadata(record.id.rawValue)
        let bytes = Data(repeating: 0x20, count: 1_048_577)
        try bytes.write(to: path)
        await #expect(throws: EnvironmentStoreError.documentTooLarge) { try await fixture.store().load(record.id) }
        #expect(try Data(contentsOf: path) == bytes)
    }

    @Test("Corrupt and mismatched documents are surfaced without rewriting them")
    func corruptDocuments() async throws {
        let fixture = try DiskFixture()
        defer { fixture.remove() }
        let id = try EnvironmentID("steam-test")
        try fixture.put("{broken", at: fixture.metadata(id.rawValue))
        await #expect(throws: (any Error).self) { try await fixture.store().loadAll() }
        #expect(try String(contentsOf: fixture.metadata(id.rawValue), encoding: .utf8) == "{broken")
        try EnvironmentDocument.encode(sampleEnvironment("other")).write(to: fixture.metadata(id.rawValue))
        await #expect(throws: EnvironmentStoreError.identityMismatch) { try await fixture.store().load(id) }
    }

    @Test("Existing unregistered prefixes are not adopted or reset")
    func preservesUnregisteredPrefix() async throws {
        let fixture = try DiskFixture()
        defer { fixture.remove() }
        let marker = fixture.prefix("steam-test").appendingPathComponent("user-data")
        try fixture.put("keep", at: marker)
        await #expect(throws: EnvironmentStoreError.prefixAlreadyExists) {
            try await fixture.store().create(sampleEnvironment())
        }
        #expect(try String(contentsOf: marker, encoding: .utf8) == "keep")
        #expect(!FileManager.default.fileExists(atPath: fixture.metadata("steam-test").path))
    }

    @Test("Root and metadata-directory symlinks cannot redirect writes")
    func refusesDirectorySymlinks() async throws {
        let fixture = try DiskFixture()
        defer { fixture.remove() }
        try FileManager.default.createSymbolicLink(at: fixture.root, withDestinationURL: fixture.outside)
        await #expect(throws: EnvironmentStoreError.unsafePath) {
            try await fixture.store().create(sampleEnvironment())
        }
        try FileManager.default.removeItem(at: fixture.root)
        try FileManager.default.createDirectory(at: fixture.root, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: fixture.root.appendingPathComponent("Metadata"),
                                                  withDestinationURL: fixture.outside)
        await #expect(throws: EnvironmentStoreError.unsafePath) {
            try await fixture.store().create(sampleEnvironment())
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.outside.path).isEmpty)
    }

    @Test("Metadata and prefix symlinks cannot escape the managed root")
    func refusesFileAndPrefixSymlinks() async throws {
        let fixture = try DiskFixture()
        defer { fixture.remove() }
        let record = try await fixture.store().create(sampleEnvironment())
        let external = fixture.outside.appendingPathComponent("record.json")
        try fixture.put("keep external", at: external)
        try FileManager.default.removeItem(at: fixture.metadata(record.id.rawValue))
        try FileManager.default.createSymbolicLink(at: fixture.metadata(record.id.rawValue), withDestinationURL: external)
        await #expect(throws: EnvironmentStoreError.unsafePath) { try await fixture.store().save(record) }
        #expect(try String(contentsOf: external, encoding: .utf8) == "keep external")
        try FileManager.default.removeItem(at: fixture.metadata(record.id.rawValue))
        try EnvironmentDocument.encode(record).write(to: fixture.metadata(record.id.rawValue))
        try FileManager.default.createDirectory(at: fixture.root.appendingPathComponent("Environments"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: fixture.prefix(record.id.rawValue), withDestinationURL: fixture.outside)
        await #expect(throws: EnvironmentStoreError.unsafePath) {
            try await fixture.store().reconcile(record.id, process: .idle, prerequisites: .ready)
        }
    }

    @Test("Restart reconciliation inspects disk and persists interrupted stage without touching prefix contents")
    func reconcilesRestart() async throws {
        let fixture = try DiskFixture()
        defer { fixture.remove() }
        var record = try await fixture.store().create(sampleEnvironment())
        record.installation = .installing(.bootstrappingSteam)
        record = try await fixture.store().save(record)
        let executable = fixture.prefix(record.id.rawValue).appendingPathComponent(record.steamExecutable.rawValue)
        try fixture.put("partial installer payload", at: executable)
        let result = try await fixture.store().reconcile(record.id, process: .idle, prerequisites: .ready)
        #expect(result.state == .interrupted(.bootstrappingSteam))
        #expect(result.files == EnvironmentFiles(prefixExists: true, executableExists: true))
        #expect(try await fixture.store().load(record.id)?.installation == .interrupted(.bootstrappingSteam))
        #expect(try String(contentsOf: executable, encoding: .utf8) == "partial installer payload")
    }

    @Test("Live versus stopped owned process facts are refreshed after reopening the store")
    func realProcessObservation() async throws {
        let fixture = try DiskFixture()
        defer { fixture.remove() }
        var record = try await fixture.store().create(sampleEnvironment())
        record.installation = .installed
        record = try await fixture.store().save(record)
        try fixture.put("test fixture", at: fixture.prefix(record.id.rawValue).appendingPathComponent(record.steamExecutable.rawValue))
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["30"]
        try child.run()
        defer { if child.isRunning { child.terminate(); child.waitUntilExit() } }
        let running = try await fixture.store().reconcile(record.id, process: child.isRunning ? .steamRunning : .idle,
                                                         prerequisites: .ready)
        #expect(running.state == .running)
        child.terminate()
        child.waitUntilExit()
        let stopped = try await fixture.store().reconcile(record.id, process: child.isRunning ? .steamRunning : .idle,
                                                         prerequisites: .ready)
        #expect(stopped.state == .installed)
        #expect(stopped.record.installation == .installed)
    }
}
