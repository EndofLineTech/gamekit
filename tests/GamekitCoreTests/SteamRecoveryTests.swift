import Foundation
import Testing
@testable import GamekitCore

private struct RecoveryFixture {
    let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store: EnvironmentStore
    let id = SteamInstallationRecipe.environmentID
    init(progress: InstallationProgress = .installed, prefix: Bool = true) async throws {
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        store = try EnvironmentStore(root: parent.appendingPathComponent("Gamekit"))
        _ = try await store.create(EnvironmentRecord(id: id, name: "Steam", runtime: RuntimeProfile.sikarugir.identity,
            installer: prefix ? .init(source: InstallerSourcePolicy.source, sha256: String(repeating: "a", count: 64), downloadedAt: Date()) : nil,
            installation: progress, installationRecipeVersion: 1))
        if prefix {
            let steam = store.prefixURL(for: id).appendingPathComponent("drive_c/Program Files (x86)/Steam")
            try FileManager.default.createDirectory(at: steam.appendingPathComponent("steamapps/common/game"), withIntermediateDirectories: true)
            try Data("GAME_BYTES".utf8).write(to: steam.appendingPathComponent("steamapps/common/game/content.bin"))
            try Data("manifest".utf8).write(to: steam.appendingPathComponent("steamapps/appmanifest_123.acf"))
            try FileManager.default.createDirectory(at: steam.appendingPathComponent("depotcache"), withIntermediateDirectories: true)
            try Data("download".utf8).write(to: steam.appendingPathComponent("depotcache/partial.bin"))
            try Data("installer fixture".utf8).write(to: steam.appendingPathComponent("Steam.exe"))
        }
    }
    func remove() { try? FileManager.default.removeItem(at: parent) }
    func completeArchiveRecovery() async throws {
        try SteamRecoveryArchive.restoreLibraries(root: store.root, id: id)
        var record = try #require(try await store.load(id))
        record.installation = .installed
        _ = try await store.save(record)
    }
    var driver: SteamRecoveryDriver { .init(observe: { _, _ in .init(processes: [], complete: true) }, stop: { _, _, _ in }) }
    func resetter(fault: @escaping @Sendable (SteamRecoveryCheckpoint) throws -> Void = { _ in }) -> SteamRecovery {
        SteamRecovery(store: store, driver: driver, quietInterval: 0, checkpoint: fault)
    }
}

private enum RecoveryFault: Error { case interrupted }

private actor InterruptedRuntime {
    let token = UUID().uuidString
    var alive = true
    var stops = 0
    func snapshot() -> RuntimeProcessSnapshot {
        .init(processes: alive ? [.init(identity: .init(pid: 12, startSeconds: 1, startMicroseconds: 0), role: .installer, sessionID: token)] : [], complete: true)
    }
    func stop(_ requested: String) { #expect(requested == token); alive = false; stops += 1 }
}

@Suite("Download-preserving Steam recovery")
struct SteamRecoveryTests {
    @Test("Archive cleanup protects pending recovery and preserves restored games and external data")
    func archiveCleanup() async throws {
        let fixture = try await RecoveryFixture(); defer { fixture.remove() }
        let outside = fixture.parent.appendingPathComponent("external-save")
        try Data("keep".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: fixture.store.prefixURL(for: fixture.id).appendingPathComponent("external-save"), withDestinationURL: outside)
        let recovery = fixture.resetter()
        _ = try await recovery.resetPreservingDownloads(confirmed: true)
        let pending = try #require(try await recovery.archives().first)
        #expect(pending.status == .protected)
        await #expect(throws: SteamRecoveryError.pendingReset) { try await recovery.cleanArchive(pending.id, confirmed: true) }
        try FileManager.default.createDirectory(at: fixture.store.prefixURL(for: fixture.id), withIntermediateDirectories: true)
        try await fixture.completeArchiveRecovery()
        let completed = try #require(try await recovery.archives().first)
        #expect(completed.status == .completed)
        #expect((completed.bytes ?? 0) > 0)
        await #expect(throws: SteamRecoveryError.confirmationRequired) { try await recovery.cleanArchive(completed.id, confirmed: false) }
        try await recovery.cleanArchive(completed.id, confirmed: true)
        #expect(try await recovery.archives().first?.status == .cleaned)
        let game = fixture.store.prefixURL(for: fixture.id).appendingPathComponent("drive_c/Program Files (x86)/Steam/steamapps/common/game/content.bin")
        #expect(try Data(contentsOf: game) == Data("GAME_BYTES".utf8))
        #expect(try Data(contentsOf: outside) == Data("keep".utf8))
        try await recovery.cleanArchive(completed.id, confirmed: true)
    }

    @Test("Completed archives remain inspectable after another reset; uncertain process ownership refuses cleanup")
    func olderArchiveCleanup() async throws {
        let fixture = try await RecoveryFixture(); defer { fixture.remove() }
        let recovery = fixture.resetter()
        _ = try await recovery.resetPreservingDownloads(confirmed: true)
        try FileManager.default.createDirectory(at: fixture.store.prefixURL(for: fixture.id), withIntermediateDirectories: true)
        try await fixture.completeArchiveRecovery()
        let completed = try #require(try await recovery.archives().first)
        _ = try await recovery.resetPreservingDownloads(confirmed: true)
        #expect(try await recovery.archives().first(where: { $0.id == completed.id })?.status == .completed)
        let uncertain = SteamRecovery(store: fixture.store, driver: .init(observe: { _, _ in .init(processes: [], complete: false) }, stop: { _, _, _ in }))
        await #expect(throws: SteamRecoveryError.observationUnavailable) { try await uncertain.cleanArchive(completed.id, confirmed: true) }
        try await recovery.cleanArchive(completed.id, confirmed: true)
        #expect(try await recovery.archives().filter { $0.status == .protected }.count == 1)
    }

    @Test("Archive cleanup refuses replacement prefixes, returned libraries, symlinks and malformed journals", arguments: ["replacement", "library", "symlink", "journal"])
    func archiveBoundaries(mutation: String) async throws {
        let fixture = try await RecoveryFixture(); defer { fixture.remove() }
        let recovery = fixture.resetter()
        _ = try await recovery.resetPreservingDownloads(confirmed: true)
        try FileManager.default.createDirectory(at: fixture.store.prefixURL(for: fixture.id), withIntermediateDirectories: true)
        try await fixture.completeArchiveRecovery()
        let completed = try #require(try await recovery.archives().first)
        let archive = fixture.store.root.appendingPathComponent("Recovery/steam/\(completed.id)")
        let prefix = archive.appendingPathComponent("prefix")
        if mutation == "replacement" || mutation == "symlink" {
            try FileManager.default.moveItem(at: prefix, to: fixture.parent.appendingPathComponent("saved-prefix"))
            if mutation == "replacement" { try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: false) }
            else { try FileManager.default.createSymbolicLink(at: prefix, withDestinationURL: fixture.store.prefixURL(for: fixture.id)) }
        } else if mutation == "library" {
            try FileManager.default.createDirectory(at: prefix.appendingPathComponent("drive_c/Program Files (x86)/Steam/steamapps"), withIntermediateDirectories: true)
        } else {
            try Data("invalid".utf8).write(to: fixture.store.root.appendingPathComponent("Metadata/Recovery/steam.json"))
        }
        await #expect(throws: (any Error).self) { try await recovery.cleanArchive(completed.id, confirmed: true) }
        #expect(FileManager.default.fileExists(atPath: prefix.path))
        let game = fixture.store.prefixURL(for: fixture.id).appendingPathComponent("drive_c/Program Files (x86)/Steam/steamapps/common/game/content.bin")
        #expect(try Data(contentsOf: game) == Data("GAME_BYTES".utf8))
    }

    @Test("Partially cleaned archive can be retried without affecting the active prefix")
    func interruptedArchiveCleanup() async throws {
        let fixture = try await RecoveryFixture(); defer { fixture.remove() }
        _ = try await fixture.resetter().resetPreservingDownloads(confirmed: true)
        try FileManager.default.createDirectory(at: fixture.store.prefixURL(for: fixture.id), withIntermediateDirectories: true)
        try await fixture.completeArchiveRecovery()
        let item = try #require(try await fixture.resetter().archives().first)
        let interrupted = fixture.resetter { if $0 == .removingEntry { throw RecoveryFault.interrupted } }
        await #expect(throws: RecoveryFault.interrupted) { try await interrupted.cleanArchive(item.id, confirmed: true) }
        try await fixture.resetter().cleanArchive(item.id, confirmed: true)
        #expect(try await fixture.resetter().archives().first?.status == .cleaned)
        #expect(FileManager.default.fileExists(atPath: fixture.store.prefixURL(for: fixture.id).path))
    }

    @Test("Legacy completed current journal is eligible; unknown historical archive stays protected")
    func legacyArchives() async throws {
        let fixture = try await RecoveryFixture(); defer { fixture.remove() }
        let recovery = fixture.resetter()
        _ = try await recovery.resetPreservingDownloads(confirmed: true)
        try FileManager.default.createDirectory(at: fixture.store.prefixURL(for: fixture.id), withIntermediateDirectories: true)
        try await fixture.completeArchiveRecovery()
        let item = try #require(try await recovery.archives().first)
        try FileManager.default.removeItem(at: fixture.store.root.appendingPathComponent("Recovery/steam/\(item.id)/completed-journal.json"))
        let unknown = UUID().uuidString.lowercased()
        try FileManager.default.createDirectory(at: fixture.store.root.appendingPathComponent("Recovery/steam/\(unknown)/prefix"), withIntermediateDirectories: true)
        #expect(try await recovery.archives().first(where: { $0.id == unknown })?.status == .protected)
        await #expect(throws: SteamRecoveryError.invalidJournal) { try await recovery.cleanArchive(unknown, confirmed: true) }
        try await recovery.cleanArchive(item.id, confirmed: true)
        #expect(try await recovery.archives().first(where: { $0.id == item.id })?.status == .cleaned)
    }

    @Test("Processes using the archive and an installation lease both block archive cleanup")
    func archiveActivity() async throws {
        let fixture = try await RecoveryFixture(); defer { fixture.remove() }
        _ = try await fixture.resetter().resetPreservingDownloads(confirmed: true)
        try FileManager.default.createDirectory(at: fixture.store.prefixURL(for: fixture.id), withIntermediateDirectories: true)
        try await fixture.completeArchiveRecovery()
        let item = try #require(try await fixture.resetter().archives().first)
        let recovery = SteamRecovery(store: fixture.store, driver: .init(observe: { _, prefix in
            .init(processes: prefix.path.contains("/Recovery/") ? [.init(identity: .init(pid: 12, startSeconds: 1, startMicroseconds: 0), role: .other, sessionID: nil)] : [], complete: true)
        }, stop: { _, _, _ in }))
        await #expect(throws: SteamRecoveryError.activeProcesses) { try await recovery.cleanArchive(item.id, confirmed: true) }
        let lease = try await fixture.store.installationLease()
        defer { withExtendedLifetime(lease) {} }
        await #expect(throws: EnvironmentStoreError.busy) { try await fixture.resetter().cleanArchive(item.id, confirmed: true) }
    }

    @Test("Restored libraries alone do not permit cleanup while installation can still need parking")
    func unfinishedInstallationArchive() async throws {
        let fixture = try await RecoveryFixture(); defer { fixture.remove() }
        let recovery = fixture.resetter()
        _ = try await recovery.resetPreservingDownloads(confirmed: true)
        try FileManager.default.createDirectory(at: fixture.store.prefixURL(for: fixture.id), withIntermediateDirectories: true)
        try SteamRecoveryArchive.restoreLibraries(root: fixture.store.root, id: fixture.id)
        let item = try #require(try await recovery.archives().first)
        #expect(item.status == .protected)
        await #expect(throws: SteamRecoveryError.pendingReset) { try await recovery.cleanArchive(item.id, confirmed: true) }
        try SteamRecoveryArchive.prepareInstallerDestination(root: fixture.store.root, id: fixture.id)
        #expect(try await recovery.archives().first?.status == .protected)
    }

    @Test("Confirmed clean reset removes a disposable real Wine prefix safely", .enabled(if: ProcessInfo.processInfo.environment["GAMEKIT_CLEAN_RESET_SMOKE"] == "1"))
    func liveCleanReset() async throws {
        let fixture = try await RecoveryFixture(); defer { fixture.remove() }
        let layout = RuntimeLayout(dataRoot: EnvironmentStore.applicationSupportRoot)
        let session = try await RuntimeSession.start(store: fixture.store, id: fixture.id, layout: layout,
            arguments: SteamInstallationRecipe.initializeArguments, timeout: 180)
        let exit = await session.command.leaderExit()
        _ = try await session.stop()
        try #require(exit == .exited(0))
        let outside = fixture.parent.appendingPathComponent("outside-save")
        try Data("keep".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: fixture.store.prefixURL(for: fixture.id).appendingPathComponent("external-save"), withDestinationURL: outside)
        let recovery = SteamRecovery(store: fixture.store, layout: layout)
        let reset = try await recovery.resetRemovingDownloads(confirmed: true)
        #expect(reset.installation == .notStarted)
        #expect(!(try await fixture.store.installationFiles(fixture.id).prefixExists))
        #expect(try Data(contentsOf: outside) == Data("keep".utf8))
        #expect(try await RuntimeDetector().detect(layout, selection: layout.profile.identity).prerequisites == .ready)
        print("Disposable Wine clean reset passed: prefix removed, external target and source runtime preserved")
    }

    @Test("Clean reset explicitly deletes the selected environment but retains older archives and external targets")
    func cleanReset() async throws {
        let fixture = try await RecoveryFixture(); defer { fixture.remove() }
        let recovery = fixture.resetter()
        await #expect(throws: SteamRecoveryError.confirmationRequired) { try await recovery.resetRemovingDownloads(confirmed: false) }
        let outside = fixture.parent.appendingPathComponent("external-save")
        try Data("outside".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: fixture.store.prefixURL(for: fixture.id).appendingPathComponent("external-link"), withDestinationURL: outside)
        let oldArchive = fixture.store.root.appendingPathComponent("Recovery/steam/older-archive")
        try FileManager.default.createDirectory(at: oldArchive, withIntermediateDirectories: true)
        try Data("archive".utf8).write(to: oldArchive.appendingPathComponent("keep"))
        let result = try await recovery.resetRemovingDownloads(confirmed: true)
        #expect(result.installation == .notStarted)
        #expect(!(try await fixture.store.installationFiles(fixture.id).prefixExists))
        #expect(try Data(contentsOf: outside) == Data("outside".utf8))
        #expect(try Data(contentsOf: oldArchive.appendingPathComponent("keep")) == Data("archive".utf8))
        let root = fixture.store.root.appendingPathComponent("Recovery/steam")
        for directory in try FileManager.default.contentsOfDirectory(atPath: root.path) where directory != "older-archive" {
            #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(directory + "/prefix").path))
        }
        #expect(try await recovery.prepareRetry() == .install)
    }

    @Test("Confirmed clean reset resumes safely through partial deletion", arguments: [SteamRecoveryCheckpoint.prepared, .archived, .deletingPrefix, .removingEntry, .prefixRemoved, .metadataReset])
    func interruptedCleanReset(point: SteamRecoveryCheckpoint) async throws {
        let fixture = try await RecoveryFixture(); defer { fixture.remove() }
        let broken = fixture.resetter { if $0 == point { throw RecoveryFault.interrupted } }
        await #expect(throws: RecoveryFault.interrupted) { try await broken.resetRemovingDownloads(confirmed: true) }
        #expect(try await fixture.resetter().prepareRetry() == .install)
        #expect(!(try await fixture.store.installationFiles(fixture.id).prefixExists))
    }

    @Test("Previously premature restoration can be parked and replayed without losing game bytes")
    func parkPrematureRestore() async throws {
        let fixture = try await RecoveryFixture(); defer { fixture.remove() }
        var record = try await fixture.resetter().resetPreservingDownloads(confirmed: true)
        record.installation = .installing(.creatingPrefix)
        record = try await fixture.store.save(record)
        try await fixture.store.createInstallationPrefix(record)
        try SteamRecoveryArchive.restoreLibraries(root: fixture.store.root, id: fixture.id) // reproduce old ordering
        #expect(throws: RecoveryFault.interrupted) {
            try SteamRecoveryArchive.prepareInstallerDestination(root: fixture.store.root, id: fixture.id) { if $0 == .libraryParked { throw RecoveryFault.interrupted } }
        }
        try SteamRecoveryArchive.prepareInstallerDestination(root: fixture.store.root, id: fixture.id)
        let steam = fixture.store.prefixURL(for: fixture.id).appendingPathComponent("drive_c/Program Files (x86)/Steam")
        #expect(try FileManager.default.contentsOfDirectory(atPath: steam.path).isEmpty)
        try Data("installed".utf8).write(to: steam.appendingPathComponent("Steam.exe"))
        try FileManager.default.createDirectory(at: steam.appendingPathComponent("steamapps"), withIntermediateDirectories: false)
        try SteamRecoveryArchive.restoreLibraries(root: fixture.store.root, id: fixture.id)
        #expect(try Data(contentsOf: steam.appendingPathComponent("steamapps/common/game/content.bin")) == Data("GAME_BYTES".utf8))
    }

    @Test("Clean reset can supersede pending preservation without deleting the older archive")
    func supersedePreservation() async throws {
        let fixture = try await RecoveryFixture(); defer { fixture.remove() }
        _ = try await fixture.resetter().resetPreservingDownloads(confirmed: true)
        let archives = fixture.store.root.appendingPathComponent("Recovery/steam")
        let original = try #require(try FileManager.default.contentsOfDirectory(atPath: archives.path).first)
        _ = try await fixture.resetter().resetRemovingDownloads(confirmed: true)
        let game = archives.appendingPathComponent(original + "/prefix/drive_c/Program Files (x86)/Steam/steamapps/common/game/content.bin")
        #expect(try Data(contentsOf: game) == Data("GAME_BYTES".utf8))
        #expect(try await fixture.resetter().prepareRetry() == .install)
    }

    @Test("A deleting phase without recorded destructive consent is rejected")
    func invalidDestructiveJournal() async throws {
        let fixture = try await RecoveryFixture(); defer { fixture.remove() }
        let broken = fixture.resetter { if $0 == .prepared { throw RecoveryFault.interrupted } }
        await #expect(throws: RecoveryFault.interrupted) { try await broken.resetPreservingDownloads(confirmed: true) }
        let file = fixture.store.root.appendingPathComponent("Metadata/Recovery/steam.json")
        var journal = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        journal["phase"] = "discarding"
        try JSONSerialization.data(withJSONObject: journal).write(to: file)
        await #expect(throws: SteamRecoveryError.invalidJournal) { try await fixture.resetter().prepareRetry() }
        #expect(try await fixture.store.installationFiles(fixture.id).executableExists)
    }

    @Test("Real Wine prefix reset preserves downloads in a disposable environment", .enabled(if: ProcessInfo.processInfo.environment["GAMEKIT_RECOVERY_SMOKE"] == "1"))
    func liveRecovery() async throws {
        let fixture = try await RecoveryFixture(); defer { fixture.remove() }
        let layout = RuntimeLayout(dataRoot: EnvironmentStore.applicationSupportRoot)
        let first = try await RuntimeSession.start(store: fixture.store, id: fixture.id, layout: layout,
            arguments: SteamInstallationRecipe.initializeArguments, timeout: 180)
        let firstExit = await first.command.leaderExit()
        _ = try await first.stop()
        try #require(firstExit == .exited(0))
        let originalIdentity = try await fixture.store.executionLease(for: fixture.id).prefixIdentity
        let recovery = SteamRecovery(store: fixture.store, layout: layout)
        _ = try await recovery.resetPreservingDownloads(confirmed: true)
        #expect(try await recovery.prepareRetry() == .install)
        var record = try #require(await fixture.store.load(fixture.id))
        record.installation = .installing(.creatingPrefix)
        record = try await fixture.store.save(record)
        try await fixture.store.createInstallationPrefix(record)
        let second = try await RuntimeSession.start(store: fixture.store, id: fixture.id, layout: layout,
            arguments: SteamInstallationRecipe.initializeArguments, timeout: 180)
        let secondExit = await second.command.leaderExit()
        _ = try await second.stop()
        try #require(secondExit == .exited(0))
        try SteamRecoveryArchive.restoreLibraries(root: fixture.store.root, id: fixture.id)
        let identity = try await fixture.store.executionLease(for: fixture.id).prefixIdentity
        #expect(originalIdentity != identity)
        let steam = fixture.store.prefixURL(for: fixture.id).appendingPathComponent("drive_c/Program Files (x86)/Steam")
        #expect(try Data(contentsOf: steam.appendingPathComponent("steamapps/common/game/content.bin")) == Data("GAME_BYTES".utf8))
        #expect(try Data(contentsOf: steam.appendingPathComponent("depotcache/partial.bin")) == Data("download".utf8))
        #expect(!FileManager.default.fileExists(atPath: steam.appendingPathComponent("Steam.exe").path))
        print("Live recovery passed: fresh Wine prefix identity, archived old installation, unchanged game and depot bytes")
    }

    @Test("Reset requires confirmation, archives only its prefix and restores downloaded games")
    func preserveGames() async throws {
        let fixture = try await RecoveryFixture(); defer { fixture.remove() }
        let recovery = fixture.resetter()
        await #expect(throws: SteamRecoveryError.confirmationRequired) { try await recovery.resetPreservingDownloads(confirmed: false) }
        let unrelated = fixture.store.root.appendingPathComponent("Environments/unrelated")
        try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: true)
        try Data("KEEP".utf8).write(to: unrelated.appendingPathComponent("keep"))
        let reset = try await recovery.resetPreservingDownloads(confirmed: true)
        #expect(reset.installation == .notStarted)
        #expect(!FileManager.default.fileExists(atPath: fixture.store.prefixURL(for: fixture.id).path))
        var pending = reset; pending.installation = .installing(.creatingPrefix)
        pending = try await fixture.store.save(pending)
        try await fixture.store.createInstallationPrefix(pending)
        try SteamRecoveryArchive.restoreLibraries(root: fixture.store.root, id: fixture.id)
        try SteamRecoveryArchive.restoreLibraries(root: fixture.store.root, id: fixture.id)
        let steam = fixture.store.prefixURL(for: fixture.id).appendingPathComponent("drive_c/Program Files (x86)/Steam")
        #expect(try Data(contentsOf: steam.appendingPathComponent("steamapps/common/game/content.bin")) == Data("GAME_BYTES".utf8))
        #expect(try Data(contentsOf: steam.appendingPathComponent("depotcache/partial.bin")) == Data("download".utf8))
        #expect(try Data(contentsOf: unrelated.appendingPathComponent("keep")) == Data("KEEP".utf8))
        #expect(!FileManager.default.fileExists(atPath: steam.appendingPathComponent("Steam.exe").path))
    }

    @Test("Reset resumes after every durable checkpoint", arguments: [SteamRecoveryCheckpoint.prepared, .archived, .metadataReset])
    func interruptedReset(point: SteamRecoveryCheckpoint) async throws {
        let fixture = try await RecoveryFixture(); defer { fixture.remove() }
        let broken = fixture.resetter { if $0 == point { throw RecoveryFault.interrupted } }
        await #expect(throws: RecoveryFault.interrupted) { try await broken.resetPreservingDownloads(confirmed: true) }
        let resumed = fixture.resetter()
        #expect(try await resumed.prepareRetry() == .install)
        #expect(try await fixture.store.load(fixture.id)?.installation == .notStarted)
    }

    @Test("A crash after moving one library resumes without overwriting or duplicating it")
    func interruptedRestore() async throws {
        let fixture = try await RecoveryFixture(); defer { fixture.remove() }
        var record = try await fixture.resetter().resetPreservingDownloads(confirmed: true)
        record.installation = .installing(.creatingPrefix)
        record = try await fixture.store.save(record)
        try await fixture.store.createInstallationPrefix(record)
        #expect(throws: RecoveryFault.interrupted) {
            try SteamRecoveryArchive.restoreLibraries(root: fixture.store.root, id: fixture.id) { if $0 == .libraryMoved { throw RecoveryFault.interrupted } }
        }
        try SteamRecoveryArchive.restoreLibraries(root: fixture.store.root, id: fixture.id)
        let steam = fixture.store.prefixURL(for: fixture.id).appendingPathComponent("drive_c/Program Files (x86)/Steam")
        #expect(try Data(contentsOf: steam.appendingPathComponent("steamapps/common/game/content.bin")) == Data("GAME_BYTES".utf8))
        #expect(try Data(contentsOf: steam.appendingPathComponent("depotcache/partial.bin")) == Data("download".utf8))
    }

    @Test("Restoration refuses a colliding library instead of overwriting it")
    func restorationCollision() async throws {
        let fixture = try await RecoveryFixture(); defer { fixture.remove() }
        var record = try await fixture.resetter().resetPreservingDownloads(confirmed: true)
        record.installation = .installing(.creatingPrefix)
        record = try await fixture.store.save(record)
        try await fixture.store.createInstallationPrefix(record)
        let library = fixture.store.prefixURL(for: fixture.id).appendingPathComponent("drive_c/Program Files (x86)/Steam/steamapps")
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        try Data("different".utf8).write(to: library.appendingPathComponent("keep"))
        #expect(throws: EnvironmentStoreError.conflict) { try SteamRecoveryArchive.restoreLibraries(root: fixture.store.root, id: fixture.id) }
        #expect(try Data(contentsOf: library.appendingPathComponent("keep")) == Data("different".utf8))
    }

    @Test("Explicit interrupted-session stop preserves files and records interruption")
    func interruptedStop() async throws {
        let fixture = try await RecoveryFixture(progress: .installing(.bootstrappingSteam)); defer { fixture.remove() }
        let runtime = InterruptedRuntime()
        let driver = SteamRecoveryDriver(observe: { _, _ in await runtime.snapshot() }, stop: { _, prefix, token in
            #expect(prefix == fixture.store.prefixURL(for: fixture.id))
            await runtime.stop(token)
        })
        let recovery = SteamRecovery(store: fixture.store, driver: driver)
        await #expect(throws: SteamRecoveryError.confirmationRequired) { try await recovery.stopInterruptedSetup(confirmed: false) }
        try await recovery.stopInterruptedSetup(confirmed: true)
        #expect(await runtime.stops == 1)
        #expect(try await fixture.store.load(fixture.id)?.installation == .interrupted(.bootstrappingSteam))
        #expect(try await fixture.store.installationFiles(fixture.id).executableExists)
    }

    @Test("Corrupt recovery journals are preserved without moving the active prefix")
    func corruptJournal() async throws {
        let fixture = try await RecoveryFixture(); defer { fixture.remove() }
        let directory = fixture.store.root.appendingPathComponent("Metadata/Recovery")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("steam.json")
        let corrupt = Data("{invalid".utf8)
        try corrupt.write(to: file)
        await #expect(throws: (any Error).self) { try await fixture.resetter().resetPreservingDownloads(confirmed: true) }
        #expect(try Data(contentsOf: file) == corrupt)
        #expect(try await fixture.store.installationFiles(fixture.id).executableExists)
    }

    @Test("Retry distinguishes missing prefix, installed files and a partial installer")
    func retryStages() async throws {
        let missing = try await RecoveryFixture(progress: .failed(.downloadFailed), prefix: false); defer { missing.remove() }
        #expect(try await missing.resetter().prepareRetry() == .install)
        let present = try await RecoveryFixture(progress: .interrupted(.bootstrappingSteam)); defer { present.remove() }
        #expect(try await present.resetter().prepareRetry() == .verifySteam)
        let partial = try await RecoveryFixture(progress: .interrupted(.runningInstaller)); defer { partial.remove() }
        try FileManager.default.removeItem(at: partial.store.prefixURL(for: partial.id).appendingPathComponent(RelativePath.steamDefault.rawValue))
        #expect(try await partial.resetter().prepareRetry() == .resumeInstaller)
    }

    @Test("Each persisted installation stage has a nondestructive retry path", arguments: [InstallationStage.downloadingInstaller, .creatingPrefix, .runningInstaller, .bootstrappingSteam, .validatingInstallation])
    func everyInterruptedStage(stage: InstallationStage) async throws {
        let fixture = try await RecoveryFixture(progress: .installing(stage), prefix: stage != .downloadingInstaller)
        defer { fixture.remove() }
        if stage == .creatingPrefix || stage == .runningInstaller {
            try FileManager.default.removeItem(at: fixture.store.prefixURL(for: fixture.id).appendingPathComponent(RelativePath.steamDefault.rawValue))
        }
        let expected: SteamRecoveryAction = stage == .downloadingInstaller ? .install :
            (stage == .creatingPrefix || stage == .runningInstaller ? .resumeInstaller : .verifySteam)
        #expect(try await fixture.resetter().prepareRetry() == expected)
        if stage != .downloadingInstaller {
            let game = fixture.store.prefixURL(for: fixture.id).appendingPathComponent("drive_c/Program Files (x86)/Steam/steamapps/common/game/content.bin")
            #expect(try Data(contentsOf: game) == Data("GAME_BYTES".utf8))
        }
    }

    @Test("Live or uncertain process inventories refuse reset and preserve files")
    func activeRefusal() async throws {
        let fixture = try await RecoveryFixture(); defer { fixture.remove() }
        for snapshot in [RuntimeProcessSnapshot(processes: [], complete: false),
                         .init(processes: [.init(identity: .init(pid: 2, startSeconds: 1, startMicroseconds: 0), role: .steam, sessionID: "foreign")], complete: true)] {
            let driver = SteamRecoveryDriver(observe: { _, _ in snapshot }, stop: { _, _, _ in Issue.record("Reset must not stop processes") })
            let recovery = SteamRecovery(store: fixture.store, driver: driver, quietInterval: 0)
            await #expect(throws: (any Error).self) { try await recovery.resetPreservingDownloads(confirmed: true) }
            #expect(try await fixture.store.installationFiles(fixture.id).executableExists)
        }
    }

    @Test("A current installation owner blocks recovery before any archive is created")
    func concurrentOwner() async throws {
        let fixture = try await RecoveryFixture(); defer { fixture.remove() }
        let lease = try await fixture.store.installationLease()
        defer { withExtendedLifetime(lease) {} }
        await #expect(throws: EnvironmentStoreError.busy) { try await fixture.resetter().resetPreservingDownloads(confirmed: true) }
        await #expect(throws: EnvironmentStoreError.busy) { try await fixture.resetter().prepareRetry() }
        #expect(!FileManager.default.fileExists(atPath: fixture.store.root.appendingPathComponent("Recovery").path))
        #expect(try await fixture.store.installationFiles(fixture.id).executableExists)
    }

    @Test("Symlinked library roots refuse reset without changing external data")
    func unsafeLibrary() async throws {
        let fixture = try await RecoveryFixture(); defer { fixture.remove() }
        let steam = fixture.store.prefixURL(for: fixture.id).appendingPathComponent("drive_c/Program Files (x86)/Steam")
        let external = fixture.parent.appendingPathComponent("outside")
        try FileManager.default.moveItem(at: steam.appendingPathComponent("steamapps"), to: external)
        try FileManager.default.createSymbolicLink(at: steam.appendingPathComponent("steamapps"), withDestinationURL: external)
        await #expect(throws: EnvironmentStoreError.unsafePath) { try await fixture.resetter().resetPreservingDownloads(confirmed: true) }
        #expect(try Data(contentsOf: external.appendingPathComponent("common/game/content.bin")) == Data("GAME_BYTES".utf8))
        #expect(try await fixture.store.installationFiles(fixture.id).executableExists)
    }
}
