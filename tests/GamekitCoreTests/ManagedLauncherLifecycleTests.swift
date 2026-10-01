import Foundation
import Testing
@testable import GamekitCore

private actor LauncherFixtureRuntime {
    var token: String?
    var prefix: String?
    var launches = 0
    var stops = 0
    var launchArguments: [String] = []
    var registryQueries: [String] = []
    var incomplete = false
    var foreign = false

    func snapshot() -> RuntimeProcessSnapshot {
        let processes: [ScopedRuntimeProcess] = token.map { session in
            [.init(identity: .init(pid: 123, startSeconds: 1, startMicroseconds: 0),
                   role: .launcher, sessionID: foreign ? "foreign" : session),
             .init(identity: .init(pid: 124, startSeconds: 1, startMicroseconds: 0),
                   role: .launcherUI, sessionID: session)]
        } ?? []
        return .init(processes: processes, complete: !incomplete)
    }
    func setForeign(_ value: Bool) { foreign = value }
    func setIncomplete(_ value: Bool) { incomplete = value }
    func exitExternally() { token = nil }
    func spawn(_ request: CommandRequest) {
        launches += 1
        token = request.environment["GAMEKIT_SESSION_ID"]
        prefix = request.environment["WINEPREFIX"]
        launchArguments = request.arguments
        #expect(request.outputMode == .discard)
        #expect(request.timeout == nil)
    }
    func execute(_ request: CommandRequest) async throws -> CommandResult {
        if request.arguments.first == "reg.exe" {
            let key = try #require(request.arguments.dropFirst(2).first)
            #expect(request.arguments == ["reg.exe", "query", key, "/s"])
            #expect(request.environment["GAMEKIT_SESSION_ID"] == token)
            #expect(request.environment["WINEPREFIX"] == prefix)
            registryQueries.append(key)
            return .init(termination: .exited(0), stdout: Data(GameFixtures.ubisoftCatalog.installs.utf8), stderr: Data(),
                stdoutBytes: GameFixtures.ubisoftCatalog.installs.utf8.count, stderrBytes: 0,
                stdoutTruncated: false, stderrTruncated: false, outputIncomplete: false, duration: 0.01)
        }
        #expect(request.arguments == ["-k"])
        #expect(request.environment["GAMEKIT_SESSION_ID"] == token)
        #expect(request.environment["WINEPREFIX"] == prefix)
        stops += 1; token = nil
        return try await ProcessExecutor().run(.init(executable: URL(fileURLWithPath: "/usr/bin/true")))
    }
    var driver: ManagedLauncherLifecycleDriver {
        .init(preflight: {}, observe: { _, _ in await self.snapshot() },
               spawn: { await self.spawn($0) }, execute: { try await self.execute($0) })
    }
}

private struct ManagedLauncherLifecycleFixture {
    let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let profile = try! LauncherProfileStore.bundled("ubisoft")
    let store: EnvironmentStore
    let layout: RuntimeLayout

    init() async throws {
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        store = try EnvironmentStore(root: parent.appendingPathComponent("Gamekit"))
        layout = RuntimeLayout(dataRoot: store.root)
        _ = try await store.create(EnvironmentRecord(id: profile.id, name: profile.name,
            runtime: layout.profile.identity,
            installer: .init(source: profile.installer.url, sha256: profile.installer.sha256, downloadedAt: Date()),
            steamExecutable: profile.executable,
            installation: .installed, installationRecipeVersion: 1))
        let file = store.prefixURL(for: profile.id).appendingPathComponent(profile.executable.rawValue)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("fixture".utf8).write(to: file)
    }
    func remove() { try? FileManager.default.removeItem(at: parent) }
}

@Suite("Persistent managed launcher ownership")
struct ManagedLauncherLifecycleTests {
    @Test("Only the launcher prefix is started, survives controller replacement and is stopped")
    func launchAndStop() async throws {
        let fixture = try await ManagedLauncherLifecycleFixture(); defer { fixture.remove() }
        let runtime = LauncherFixtureRuntime()
        let lifecycle = try ManagedLauncherLifecycle(store: fixture.store, layout: fixture.layout,
            profile: fixture.profile, driver: await runtime.driver)
        #expect(try await lifecycle.status() == .stopped)
        _ = try await lifecycle.launch()
        #expect(try await lifecycle.status() == .running)
        #expect(try await lifecycle.show() == 123)
        _ = try await lifecycle.launch()
        #expect(await runtime.launches == 1)
        #expect(await runtime.launchArguments == [fixture.store.prefixURL(for: fixture.profile.id)
            .appendingPathComponent(fixture.profile.executable.rawValue).path] + (fixture.profile.launchArguments ?? []))
        #expect(await runtime.prefix == fixture.store.prefixURL(for: fixture.profile.id).path)
        let settings = RuntimeSettingsStore(store: fixture.store)
        #expect(try await settings.isSelectionLocked())
        await #expect(throws: EnvironmentStoreError.busy) { try await settings.selectGraphicsBackend(.metal3) }

        let steamReceipt = fixture.store.root.appendingPathComponent("Metadata/Lifecycle/steam.json")
        let original = Data("unrelated Steam receipt".utf8)
        try original.write(to: steamReceipt)
        let reopened = try ManagedLauncherLifecycle(store: fixture.store, layout: fixture.layout,
            profile: fixture.profile, driver: await runtime.driver)
        #expect(try await reopened.status() == .running, "Ordinary Gamekit Quit does not stop the owned launcher")
        #expect(try await reopened.stop() == .stopped)
        #expect(try Data(contentsOf: steamReceipt) == original)
        #expect(try await reopened.status() == .stopped)
        #expect(try await settings.isSelectionLocked(), "Steam's separate receipt still locks shared runtime changes")
        #expect(await runtime.stops == 1)
        #expect(try await reopened.stop() == .alreadyStopped)
        try FileManager.default.removeItem(at: steamReceipt)
        #expect(try await !settings.isSelectionLocked())
    }

    @Test("An externally exited owned client settles from Starting to Stopped before relaunch")
    func externalExitSettles() async throws {
        let fixture = try await ManagedLauncherLifecycleFixture(); defer { fixture.remove() }
        let runtime = LauncherFixtureRuntime()
        let lifecycle = try ManagedLauncherLifecycle(store: fixture.store, layout: fixture.layout,
            profile: fixture.profile, driver: await runtime.driver)
        #expect(try await lifecycle.launch() == .running)
        await runtime.exitExternally()
        #expect(try await lifecycle.status() == .starting)
        try await Task.sleep(for: .seconds(5.1))
        #expect(try await lifecycle.status() == .stopped)
        #expect(try await lifecycle.launch() == .running)
        #expect(await runtime.launches == 2)
        #expect(try await lifecycle.stop() == .stopped)
    }

    @Test("Foreign or incomplete observation refuses Stop and preserves the receipt")
    func refuseUncertainStop() async throws {
        let fixture = try await ManagedLauncherLifecycleFixture(); defer { fixture.remove() }
        let runtime = LauncherFixtureRuntime()
        let lifecycle = try ManagedLauncherLifecycle(store: fixture.store, layout: fixture.layout,
            profile: fixture.profile, driver: await runtime.driver)
        _ = try await lifecycle.launch()
        await runtime.setIncomplete(true)
        await #expect(throws: ManagedLauncherLifecycleError.observationUnavailable) { try await lifecycle.stop() }
        await runtime.setIncomplete(false)
        await runtime.setForeign(true)
        await #expect(throws: ManagedLauncherLifecycleError.foreignActivity) { try await lifecycle.stop() }
        #expect(await runtime.stops == 0)
        #expect(FileManager.default.fileExists(atPath: fixture.store.root.appendingPathComponent("Metadata/Lifecycle/\(fixture.profile.id.rawValue).json").path))
        await runtime.setForeign(false)
        #expect(try await lifecycle.stop() == .stopped)
    }

    @Test("A replaced prefix cannot inherit an earlier launch receipt")
    func changedPrefix() async throws {
        let fixture = try await ManagedLauncherLifecycleFixture(); defer { fixture.remove() }
        let runtime = LauncherFixtureRuntime()
        let lifecycle = try ManagedLauncherLifecycle(store: fixture.store, layout: fixture.layout,
            profile: fixture.profile, driver: await runtime.driver)
        _ = try await lifecycle.launch()
        let prefix = fixture.store.prefixURL(for: fixture.profile.id)
        try FileManager.default.moveItem(at: prefix, to: fixture.parent.appendingPathComponent("displaced"))
        let file = prefix.appendingPathComponent(fixture.profile.executable.rawValue)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("replacement".utf8).write(to: file)
        await #expect(throws: ManagedLauncherLifecycleError.scopeChanged) { try await lifecycle.stop() }
        await #expect(throws: ManagedLauncherLifecycleError.scopeChanged) { try await lifecycle.recoverStoppedReceipt() }
        #expect(await runtime.stops == 0)
    }

    @Test("A reboot-renumbered device can retire only an idle receipt for the same prefix inode")
    func renumberedDevice() async throws {
        let fixture = try await ManagedLauncherLifecycleFixture(); defer { fixture.remove() }
        let runtime = LauncherFixtureRuntime()
        let lifecycle = try ManagedLauncherLifecycle(store: fixture.store, layout: fixture.layout,
            profile: fixture.profile, driver: await runtime.driver)
        _ = try await lifecycle.launch()
        let receipt = fixture.store.root.appendingPathComponent("Metadata/Lifecycle/\(fixture.profile.id.rawValue).json")
        var saved = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: receipt)) as? [String: Any])
        saved["device"] = try #require(saved["device"] as? Int) + 1
        try JSONSerialization.data(withJSONObject: saved).write(to: receipt)
        await #expect(throws: ManagedLauncherLifecycleError.scopeChanged) { try await lifecycle.status() }
        await #expect(throws: ManagedLauncherLifecycleError.foreignActivity) { try await lifecycle.recoverStoppedReceipt() }
        #expect(FileManager.default.fileExists(atPath: receipt.path))
        await runtime.setIncomplete(true)
        await runtime.exitExternally()
        await #expect(throws: ManagedLauncherLifecycleError.observationUnavailable) { try await lifecycle.recoverStoppedReceipt() }
        #expect(FileManager.default.fileExists(atPath: receipt.path))
        await runtime.setIncomplete(false)
        try await lifecycle.recoverStoppedReceipt()
        #expect(!FileManager.default.fileExists(atPath: receipt.path))
        #expect(try await lifecycle.status() == .stopped)
        #expect(await runtime.stops == 0)
        #expect(try await lifecycle.launch() == .running)
        #expect(try await lifecycle.stop() == .stopped)
    }

    @Test("Registry discovery and vendor Play require the same owned launcher session")
    func registeredGames() async throws {
        let fixture = try await ManagedLauncherLifecycleFixture(); defer { fixture.remove() }
        let runtime = LauncherFixtureRuntime()
        let lifecycle = try ManagedLauncherLifecycle(store: fixture.store, layout: fixture.layout,
            profile: fixture.profile, driver: await runtime.driver)
        let catalog = try #require(fixture.profile.gameCatalog)
        let id = GameFixtures.ubisoftCatalog.id
        await #expect(throws: ManagedLauncherLifecycleError.observationUnavailable) {
            try await lifecycle.gameRegistry(catalog.installsRegistryKey)
        }
        _ = try await lifecycle.launch()
        #expect(try await lifecycle.gameRegistry(catalog.installsRegistryKey) == GameFixtures.ubisoftCatalog.installs)
        #expect(await runtime.registryQueries == [catalog.installsRegistryKey])
        await #expect(throws: ManagedLauncherLifecycleError.gameUnavailable) {
            try await lifecycle.gameRegistry("HKLM\\Software\\Unrelated")
        }
        await runtime.setForeign(true)
        await #expect(throws: ManagedLauncherLifecycleError.foreignActivity) {
            try await lifecycle.gameRegistry(catalog.installsRegistryKey)
        }
        await #expect(throws: ManagedLauncherLifecycleError.foreignActivity) {
            try await lifecycle.requestGameLaunch(id)
        }
        await runtime.setForeign(false)
        try await lifecycle.requestGameLaunch(id)
        #expect(await runtime.launches == 2)
        #expect(await runtime.launchArguments == [fixture.store.prefixURL(for: fixture.profile.id)
            .appendingPathComponent(fixture.profile.executable.rawValue).path,
            catalog.launchURI.replacingOccurrences(of: "{id}", with: String(id))])
        #expect(try await lifecycle.stop() == .stopped)
        await #expect(throws: ManagedLauncherLifecycleError.observationUnavailable) {
            try await lifecycle.requestGameLaunch(id)
        }
    }
}
