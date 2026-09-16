import Foundation
import Testing
@testable import GamekitCore

private struct InstallationFixture {
    let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    var root: URL { parent.appendingPathComponent("Gamekit") }
    let id = try! EnvironmentID("steam")
    init() throws { try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true) }
    func remove() { try? FileManager.default.removeItem(at: parent) }
}

private actor InstallationProbe {
    var stages: [InstallationStage] = []
    var stops = 0
    var waiting = false
    var observations = 0
    func record(_ stage: InstallationStage) { stages.append(stage) }
    func stopped() { stops += 1 }
    func handoffSnapshot() -> RuntimeProcessSnapshot {
        observations += 1
        return .init(processes: observations < 3 ? [] : [.init(identity: .init(pid: 123, startSeconds: 1, startMicroseconds: 0), role: .steam, sessionID: "fixture")], complete: observations != 1)
    }
    func wait() async throws {
        waiting = true
        try await Task.sleep(for: .seconds(30))
    }
}

private func installationDriver(_ fixture: InstallationFixture, probe: InstallationProbe,
                                failing: InstallationStage? = nil) -> SteamInstallationDriver {
    let artifact = InstallerArtifact(schemaVersion: 1, id: UUID(), provenance: .init(source: InstallerSourcePolicy.source,
        sha256: String(repeating: "a", count: 64), downloadedAt: Date()), finalURL: InstallerSourcePolicy.source, byteCount: 1024)
    return SteamInstallationDriver(preflight: {}, acquire: { artifact }, artifactURL: { _ in fixture.parent.appendingPathComponent("installer.exe") },
        start: { record, _, _, _ in
            guard case .installing(let stage) = record.installation else { throw MetadataError.invalidRecord }
            await probe.record(stage)
            if stage == .runningInstaller && failing != stage {
                let exe = fixture.root.appendingPathComponent("Environments/steam/\(record.steamExecutable.rawValue)")
                try FileManager.default.createDirectory(at: exe.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data("fixture executable".utf8).write(to: exe)
            }
            return SteamInstallationProcess(leaderExit: { failing == stage ? .exited(23) : .exited(0) },
                snapshot: { .init(processes: stage == .bootstrappingSteam ? [.init(identity: .init(pid: 123, startSeconds: 1, startMicroseconds: 0), role: .steam, sessionID: "fixture")] : [], complete: true) },
                stop: { await probe.stopped() })
        })
}

@Suite("Managed Steam installation")
struct SteamInstallationTests {
    @Test("Installer exit alone is not readiness; confirmation commits installation exactly once")
    func successfulInstall() async throws {
        let fixture = try InstallationFixture(); defer { fixture.remove() }
        let store = try EnvironmentStore(root: fixture.root)
        let probe = InstallationProbe()
        let coordinator = SteamInstallationCoordinator(store: store, driver: installationDriver(fixture, probe: probe))
        let record = try await coordinator.install(id: fixture.id, confirmUsableUI: {
            let saved = try await store.load(fixture.id)
            #expect(saved?.installation == .installing(.validatingInstallation))
            return true
        })
        #expect(record.installation == .installed)
        #expect(record.installationRecipeVersion == 1)
        #expect(await probe.stages == [.creatingPrefix, .runningInstaller, .bootstrappingSteam])
        #expect(await probe.stops == 3)
        let repeated = try await coordinator.install(id: fixture.id, confirmUsableUI: { Issue.record("Must not reinstall"); return false })
        #expect(repeated == record)
        #expect(await probe.stages.count == 3)
    }

    @Test("Existing unregistered prefixes are preserved, never adopted")
    func existingPrefix() async throws {
        let fixture = try InstallationFixture(); defer { fixture.remove() }
        let prefix = fixture.root.appendingPathComponent("Environments/steam")
        try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: true)
        let marker = prefix.appendingPathComponent("keep")
        try Data("preserve".utf8).write(to: marker)
        let store = try EnvironmentStore(root: fixture.root)
        let coordinator = SteamInstallationCoordinator(store: store, driver: installationDriver(fixture, probe: InstallationProbe()))
        await #expect(throws: EnvironmentStoreError.prefixAlreadyExists) {
            try await coordinator.install(id: fixture.id, confirmUsableUI: { true })
        }
        #expect(try Data(contentsOf: marker) == Data("preserve".utf8))
        #expect(try await store.load(fixture.id) == nil)
    }

    @Test("Failed installers persist their stage and cannot be silently rerun")
    func failedInstaller() async throws {
        let fixture = try InstallationFixture(); defer { fixture.remove() }
        let store = try EnvironmentStore(root: fixture.root)
        let coordinator = SteamInstallationCoordinator(store: store, driver: installationDriver(fixture, probe: InstallationProbe(), failing: .runningInstaller))
        await #expect(throws: (any Error).self) { try await coordinator.install(id: fixture.id, confirmUsableUI: { true }) }
        #expect(try await store.load(fixture.id)?.installation == .failed(.installerFailed))
        await #expect(throws: SteamInstallationError.recoveryRequired) { try await coordinator.install(id: fixture.id, confirmUsableUI: { true }) }
    }

    @Test("Active install ownership blocks a second coordinator and idle reconciliation")
    func ownershipAndCancellation() async throws {
        let fixture = try InstallationFixture(); defer { fixture.remove() }
        let store = try EnvironmentStore(root: fixture.root)
        let probe = InstallationProbe()
        let coordinator = SteamInstallationCoordinator(store: store, driver: installationDriver(fixture, probe: probe))
        let task = Task { try await coordinator.install(id: fixture.id, confirmUsableUI: { try await probe.wait(); return true }) }
        while !(await probe.waiting) { try await Task.sleep(for: .milliseconds(1)) }
        let other = SteamInstallationCoordinator(store: store, driver: installationDriver(fixture, probe: InstallationProbe()))
        await #expect(throws: EnvironmentStoreError.busy) { try await other.install(id: fixture.id, confirmUsableUI: { true }) }
        await #expect(throws: EnvironmentStoreError.busy) { try await store.reconcile(fixture.id, process: .idle, prerequisites: .ready) }
        var changed = try #require(await store.load(fixture.id))
        changed.installationRecipeVersion = nil
        await #expect(throws: EnvironmentStoreError.busy) { try await store.save(changed) }
        task.cancel()
        await #expect(throws: (any Error).self) { try await task.value }
        #expect(try await store.load(fixture.id)?.installation == .interrupted(.validatingInstallation))
        #expect(await probe.stops == 3)
    }

    @Test("Updater handoff gaps and original launcher exit do not imply bootstrap completion")
    func bootstrapHandoff() async throws {
        let fixture = try InstallationFixture(); defer { fixture.remove() }
        let store = try EnvironmentStore(root: fixture.root)
        let probe = InstallationProbe()
        let base = installationDriver(fixture, probe: probe)
        let driver = SteamInstallationDriver(preflight: base.preflight, acquire: base.acquire, artifactURL: base.artifactURL,
            start: { record, arguments, timeout, operation in
                let process = try await base.start(record, arguments, timeout, operation)
                if record.installation == .installing(.bootstrappingSteam) {
                    return SteamInstallationProcess(leaderExit: { .exited(0) }, snapshot: { await probe.handoffSnapshot() }, stop: process.stop)
                }
                return process
            })
        let coordinator = SteamInstallationCoordinator(store: store, driver: driver)
        let installed = try await coordinator.install(id: fixture.id, confirmUsableUI: { true })
        #expect(installed.installation == .installed)
        #expect(await probe.observations >= 4)
    }

    @Test("Declining UI confirmation preserves a recoverable prefix without claiming installation")
    func declinedConfirmation() async throws {
        let fixture = try InstallationFixture(); defer { fixture.remove() }
        let store = try EnvironmentStore(root: fixture.root)
        let coordinator = SteamInstallationCoordinator(store: store, driver: installationDriver(fixture, probe: InstallationProbe()))
        await #expect(throws: SteamInstallationError.confirmationDeclined) {
            try await coordinator.install(id: fixture.id, confirmUsableUI: { false })
        }
        #expect(try await store.load(fixture.id)?.installation == .interrupted(.validatingInstallation))
        #expect(try await store.installationFiles(fixture.id).executableExists)
    }

    @Test("Explicit verification retry reuses installed files without prefix initialization or installer execution")
    func verificationRetry() async throws {
        let fixture = try InstallationFixture(); defer { fixture.remove() }
        let store = try EnvironmentStore(root: fixture.root)
        let probe = InstallationProbe()
        let coordinator = SteamInstallationCoordinator(store: store, driver: installationDriver(fixture, probe: probe))
        await #expect(throws: SteamInstallationError.confirmationDeclined) {
            try await coordinator.install(id: fixture.id, confirmUsableUI: { false })
        }
        let before = try #require(await store.load(fixture.id))
        let verified = try await coordinator.verifyExistingInstallation(id: fixture.id, confirmUsableUI: { true })
        #expect(verified.installation == .installed)
        #expect(verified.createdAt == before.createdAt && verified.installer == before.installer)
        #expect(await probe.stages == [.creatingPrefix, .runningInstaller, .bootstrappingSteam, .bootstrappingSteam])
        await #expect(throws: SteamInstallationError.recoveryRequired) {
            try await coordinator.verifyExistingInstallation(id: fixture.id, confirmUsableUI: { true })
        }
    }

    @Test("Cleanup refusal retains ownership and durable in-progress state")
    func cleanupRefusal() async throws {
        let fixture = try InstallationFixture(); defer { fixture.remove() }
        let store = try EnvironmentStore(root: fixture.root)
        let base = installationDriver(fixture, probe: InstallationProbe())
        let driver = SteamInstallationDriver(preflight: base.preflight, acquire: base.acquire, artifactURL: base.artifactURL,
            start: { _, _, _, _ in
                .init(leaderExit: { .exited(0) }, snapshot: { .init(processes: [], complete: false) },
                      stop: { throw RuntimeSessionError.cleanupFailed })
            })
        let coordinator = SteamInstallationCoordinator(store: store, driver: driver)
        await #expect(throws: RuntimeSessionError.cleanupFailed) { try await coordinator.install(id: fixture.id, confirmUsableUI: { true }) }
        #expect(try await store.load(fixture.id)?.installation == .installing(.creatingPrefix))
        let other = SteamInstallationCoordinator(store: store, driver: base)
        await #expect(throws: EnvironmentStoreError.busy) { try await other.install(id: fixture.id, confirmUsableUI: { true }) }
    }

    @Test("Installation diagnostics record stage progression separately from durable metadata")
    func installationDiagnostics() async throws {
        let fixture = try InstallationFixture(); defer { fixture.remove() }
        let store = try EnvironmentStore(root: fixture.root)
        let diagnostics = try DiagnosticStore(base: fixture.parent.appendingPathComponent("Logs"))
        let coordinator = SteamInstallationCoordinator(store: store, driver: installationDriver(fixture, probe: InstallationProbe()), diagnostics: diagnostics)
        _ = try await coordinator.install(id: fixture.id, confirmUsableUI: { true })
        let summary = try #require(await diagnostics.summaries().first)
        #expect(summary.events.map(\.stage) == [.download, .installation, .bootstrap, .rendering])
        #expect(summary.outcome == .exited(0))
        #expect(!(String(decoding: try await diagnostics.exportSummary(summary.id), as: UTF8.self).contains(fixture.root.path)))
    }
}
