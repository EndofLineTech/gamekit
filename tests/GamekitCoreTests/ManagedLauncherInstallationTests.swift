import Foundation
import Testing
@testable import GamekitCore

private struct ManagedLauncherFixture {
    let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let profile = try! LauncherProfileStore.bundled("ubisoft")
    var root: URL { parent.appendingPathComponent("Gamekit") }
    var installer: URL { parent.appendingPathComponent("installer.exe") }
    func prepare() throws { try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true) }
    func remove() { try? FileManager.default.removeItem(at: parent) }

    var artifact: InstallerArtifact {
        .init(schemaVersion: 1, id: UUID(), provenance: .init(source: profile.installer.url,
            sha256: profile.installer.sha256, downloadedAt: Date()), finalURL: profile.installer.url, byteCount: 1024)
    }

    func driver(preflight: @escaping @Sendable () async throws -> Void = {},
                installerExit: CommandTermination = .exited(0)) -> ManagedLauncherInstallationDriver {
        let profile = profile; let artifact = artifact; let installer = installer; let root = root
        return .init(preflight: preflight, acquire: { artifact }, artifactURL: { _ in installer },
            start: { record, arguments, _ in
                if arguments.first == installer.path, installerExit == .exited(0) {
                    let executable = root.appendingPathComponent("Environments/\(record.id.rawValue)/\(profile.executable.rawValue)")
                    try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try Data("fixture".utf8).write(to: executable)
                }
                let result: CommandTermination? = arguments.count == 1 && arguments.first != installer.path ? nil
                    : arguments.first == installer.path ? installerExit : .exited(0)
                return .init(leaderExit: { result }, snapshot: {
                    let client = ScopedRuntimeProcess(identity: .init(pid: 42, startSeconds: 1, startMicroseconds: 0),
                                                       role: .launcher, sessionID: "fixture")
                    let web = ScopedRuntimeProcess(identity: .init(pid: 43, startSeconds: 1, startMicroseconds: 0),
                                                    role: .launcherUI, sessionID: "fixture")
                    return .init(processes: [client, web], complete: true)
                }, stop: {})
            }, uiReady: { snapshot in
                snapshot.complete && snapshot.processes.contains(where: { $0.role == .launcher }) &&
                    snapshot.processes.contains(where: { $0.role == .launcherUI })
            }, readinessStability: 0)
    }
}

@Suite("Isolated managed launcher installation")
struct ManagedLauncherInstallationTests {
    @Test("Installation registers only the launcher prefix and waits for client and UI helpers")
    func install() async throws {
        let fixture = ManagedLauncherFixture(); try fixture.prepare(); defer { fixture.remove() }
        let store = try EnvironmentStore(root: fixture.root)
        let steam = try await store.create(EnvironmentRecord(id: SteamInstallationRecipe.environmentID,
            name: "Windows Steam", installation: .installed, installationRecipeVersion: 1))
        let coordinator = try ManagedLauncherInstallationCoordinator(store: store,
            layout: RuntimeLayout(dataRoot: fixture.root), profile: fixture.profile, driver: fixture.driver())
        let result = try await coordinator.install()
        #expect(result.installation == .installed)
        #expect(result.id == fixture.profile.id)
        #expect(result.steamExecutable == fixture.profile.executable)
        #expect(result.installer?.sha256 == fixture.profile.installer.sha256)
        #expect(try await store.installationFiles(result.id).executableExists)
        #expect(try await store.load(SteamInstallationRecipe.environmentID) == steam)
        #expect(!FileManager.default.fileExists(atPath: store.prefixURL(for: SteamInstallationRecipe.environmentID).path))
        #expect(try await coordinator.install() == result, "Repeated Install must not run another installer")
    }

    @Test("Prerequisite failure does not create a managed launcher record or prefix")
    func preflight() async throws {
        let fixture = ManagedLauncherFixture(); try fixture.prepare(); defer { fixture.remove() }
        let store = try EnvironmentStore(root: fixture.root)
        let coordinator = try ManagedLauncherInstallationCoordinator(store: store,
            layout: RuntimeLayout(dataRoot: fixture.root), profile: fixture.profile,
            driver: fixture.driver(preflight: { throw ManagedLauncherInstallationError.prerequisitesNotReady }))
        await #expect(throws: ManagedLauncherInstallationError.prerequisitesNotReady) { try await coordinator.install() }
        #expect(try await store.load(fixture.profile.id) == nil)
        #expect(!FileManager.default.fileExists(atPath: store.prefixURL(for: fixture.profile.id).path))
    }

    @Test("A stopped installer failure remains recoverable without resetting an owned prefix")
    func failedInstaller() async throws {
        let fixture = ManagedLauncherFixture(); try fixture.prepare(); defer { fixture.remove() }
        let store = try EnvironmentStore(root: fixture.root)
        let coordinator = try ManagedLauncherInstallationCoordinator(store: store,
            layout: RuntimeLayout(dataRoot: fixture.root), profile: fixture.profile,
            driver: fixture.driver(installerExit: .exited(42)))
        await #expect(throws: ManagedLauncherInstallationError.commandFailed) { try await coordinator.install() }
        #expect(try await store.load(fixture.profile.id)?.installation == .failed(.installerFailed))
        #expect(try await store.installationFiles(fixture.profile.id).prefixExists)
        await #expect(throws: ManagedLauncherInstallationError.recoveryRequired) { try await coordinator.install() }
    }
}
