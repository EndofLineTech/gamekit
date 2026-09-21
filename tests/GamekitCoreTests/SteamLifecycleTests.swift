import Foundation
import Testing
@testable import GamekitCore

private actor LifecycleFixtureRuntime {
    var token: String?
    var prefix: String?
    var launches = 0
    var forced = false
    var graceful = true
    var orphan = false
    var signalled = false
    var commands: [[String]] = []
    var observationScript: [Bool] = []
    var shutdownScript: [Bool] = []
    var observations = 0
    func observeCompleteness(_ values: [Bool]) { observationScript = values; observations = 0 }
    func afterShutdownCompleteness(_ values: [Bool]) { shutdownScript = values }
    func foreign() { token = "foreign" }
    func refuseGraceful() { graceful = false }
    func leaveOrphan() { graceful = false; orphan = true }
    func handoffGap() { token = nil }
    func snapshot() -> RuntimeProcessSnapshot {
        observations += 1
        let complete = observationScript.isEmpty ? true : observationScript.removeFirst()
        return .init(processes: token.map { [.init(identity: .init(pid: 123, startSeconds: 1, startMicroseconds: 0), role: .steam, sessionID: $0)] } ?? [], complete: complete)
    }
    func spawn(_ request: CommandRequest) {
        launches += 1; token = request.environment["GAMEKIT_SESSION_ID"]
        prefix = request.environment["WINEPREFIX"]
        #expect(request.outputMode == .discard)
        #expect(request.timeout == nil)
    }
    func execute(_ request: CommandRequest) async throws -> CommandResult {
        commands.append(request.arguments)
        #expect(prefix != nil && request.environment["WINEPREFIX"] == prefix)
        #expect(request.environment["GAMEKIT_SESSION_ID"] == token)
        if request.arguments == ["-k"] { forced = true; if !orphan { token = nil } }
        else if request.arguments.last == "-shutdown", graceful { token = nil; observationScript = shutdownScript }
        return try await ProcessExecutor().run(.init(executable: URL(fileURLWithPath: "/usr/bin/true")))
    }
    var driver: SteamLifecycleDriver {
        .init(preflight: {}, observe: { _, _ in await self.snapshot() }, spawn: { await self.spawn($0) }, execute: { try await self.execute($0) },
              signalRemaining: { processes, _ in await self.signal(processes) })
    }
    func signal(_ processes: [ScopedRuntimeProcess]) {
        if !processes.isEmpty { #expect(processes.allSatisfy { $0.sessionID == token }); signalled = true; token = nil }
    }
}

private struct LifecycleFixture {
    let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store: EnvironmentStore
    let id = SteamInstallationRecipe.environmentID
    init() async throws {
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        store = try EnvironmentStore(root: parent.appendingPathComponent("Gamekit"))
        _ = try await store.create(EnvironmentRecord(id: id, name: "Steam", runtime: RuntimeProfile.sikarugir.identity,
            installation: .installed, installationRecipeVersion: 1))
        let exe = store.prefixURL(for: id).appendingPathComponent(RelativePath.steamDefault.rawValue)
        try FileManager.default.createDirectory(at: exe.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("fixture".utf8).write(to: exe)
    }
    func remove() { try? FileManager.default.removeItem(at: parent) }
    func game(state: SteamGameInstallState = .ready) throws -> URL {
        let steam = store.prefixURL(for: id).appendingPathComponent(RelativePath.steamDefault.rawValue).deletingLastPathComponent()
        let apps = steam.appendingPathComponent("steamapps")
        try FileManager.default.createDirectory(at: apps, withIntermediateDirectories: true)
        if state != .missingFiles {
            try FileManager.default.createDirectory(at: apps.appendingPathComponent("common/Fixture"), withIntermediateDirectories: true)
            try Data("game content".utf8).write(to: apps.appendingPathComponent("common/Fixture/game.bin"))
        }
        let manifest = apps.appendingPathComponent("appmanifest_42.acf")
        try Data("\"AppState\" { \"appid\" \"42\" \"name\" \"Fixture\" \"installdir\" \"Fixture\" \"StateFlags\" \"\(state == .updating ? 1026 : 4)\" }".utf8).write(to: manifest)
        return manifest
    }
}

@Suite("Persistent Steam lifecycle")
struct SteamLifecycleTests {
    @Test("Uninstall requests use owned Windows Steam for ready, partial and missing-file installations",
          arguments: [SteamGameInstallState.ready, .updating, .missingFiles], [false, true])
    func requestUninstall(state: SteamGameInstallState, alreadyRunning: Bool) async throws {
        let fixture = try await LifecycleFixture(); defer { fixture.remove() }
        let manifest = try fixture.game(state: state)
        let before = try Data(contentsOf: manifest)
        let save = fixture.store.prefixURL(for: fixture.id).appendingPathComponent("save.sav")
        try Data("saved progress".utf8).write(to: save)
        let runtime = LifecycleFixtureRuntime()
        let base = await runtime.driver
        let layout = RuntimeLayout(dataRoot: fixture.store.root)
        let driver = SteamLifecycleDriver(preflight: base.preflight, observe: base.observe, spawn: base.spawn, execute: { request in
            #expect(request.executable == layout.wine)
            #expect(request.arguments == [fixture.store.prefixURL(for: fixture.id).appendingPathComponent(RelativePath.steamDefault.rawValue).path, "steam://uninstall/42"])
            #expect(request.timeout == 10 && request.outputLimit == 8192)
            return try await base.execute(request)
        })
        let lifecycle = SteamLifecycle(store: fixture.store, driver: driver)
        if alreadyRunning { _ = try await lifecycle.launch() }
        try await lifecycle.requestGameUninstall(appID: 42)
        #expect(await runtime.launches == 1)
        #expect(await runtime.commands.count == 1)
        #expect(try Data(contentsOf: manifest) == before, "A delivered request is not completed removal")
        #expect(try Data(contentsOf: save) == Data("saved progress".utf8))
        if state != .missingFiles {
            #expect(try Data(contentsOf: manifest.deletingLastPathComponent().appendingPathComponent("common/Fixture/game.bin")) == Data("game content".utf8))
        }
    }

    @Test("Uninstall rejects unknown, malformed and removed-during-startup targets", arguments: ["unknown", "malformed", "removed"])
    func uninstallRevalidatesTarget(_ scenario: String) async throws {
        let fixture = try await LifecycleFixture(); defer { fixture.remove() }
        let manifest = try fixture.game()
        if scenario == "malformed" { try Data("invalid".utf8).write(to: manifest) }
        let runtime = LifecycleFixtureRuntime()
        let base = await runtime.driver
        let driver = SteamLifecycleDriver(preflight: base.preflight, observe: base.observe, spawn: { request in
            await runtime.spawn(request)
            if scenario == "removed" { try FileManager.default.removeItem(at: manifest) }
        }, execute: base.execute)
        let lifecycle = SteamLifecycle(store: fixture.store, driver: driver)
        await #expect(throws: SteamGameLibraryError.notInstalled) {
            try await lifecycle.requestGameUninstall(appID: scenario == "unknown" ? 0 : 42)
        }
        #expect(await runtime.commands.isEmpty)
        #expect(await runtime.launches == (scenario == "removed" ? 1 : 0))
    }

    @Test("Uninstall refuses changed ownership, uncertain observation and cancellation before dispatch", arguments: ["foreign", "incomplete", "cancelled"])
    func uninstallOwnership(_ scenario: String) async throws {
        let fixture = try await LifecycleFixture(); defer { fixture.remove() }
        _ = try fixture.game()
        let runtime = LifecycleFixtureRuntime()
        let base = await runtime.driver
        _ = try await SteamLifecycle(store: fixture.store, driver: base).launch()
        let driver = SteamLifecycleDriver(preflight: {
            if scenario == "foreign" { await runtime.foreign() }
            if scenario == "incomplete" { await runtime.observeCompleteness([false]) }
            if scenario == "cancelled" { throw CancellationError() }
        }, observe: base.observe, spawn: base.spawn, execute: base.execute)
        let lifecycle = SteamLifecycle(store: fixture.store, driver: driver)
        if scenario == "cancelled" {
            await #expect(throws: CancellationError.self) { try await lifecycle.requestGameUninstall(appID: 42) }
        } else {
            await #expect(throws: scenario == "foreign" ? SteamLifecycleError.foreignActivity : .observationUnavailable) {
                try await lifecycle.requestGameUninstall(appID: 42)
            }
        }
        #expect(await runtime.commands.isEmpty)
    }

    @Test("Failed uninstall dispatch reports failure and retains the installation")
    func uninstallDispatchFailure() async throws {
        let fixture = try await LifecycleFixture(); defer { fixture.remove() }
        let manifest = try fixture.game()
        let runtime = LifecycleFixtureRuntime()
        let base = await runtime.driver
        let driver = SteamLifecycleDriver(preflight: base.preflight, observe: base.observe, spawn: base.spawn, execute: { request in
            _ = try await base.execute(request)
            return try await ProcessExecutor().run(.init(executable: URL(fileURLWithPath: "/usr/bin/false")))
        })
        let lifecycle = SteamLifecycle(store: fixture.store, driver: driver)
        await #expect(throws: SteamLifecycleError.observationUnavailable) { try await lifecycle.requestGameUninstall(appID: 42) }
        #expect(await runtime.commands.count == 1)
        #expect(FileManager.default.fileExists(atPath: manifest.path))
    }

    @Test("Uninstall refuses a conflicting execution lease")
    func uninstallBusyLease() async throws {
        let fixture = try await LifecycleFixture(); defer { fixture.remove() }
        _ = try fixture.game()
        let runtime = LifecycleFixtureRuntime()
        let lifecycle = SteamLifecycle(store: fixture.store, driver: await runtime.driver)
        let lease = try await fixture.store.executionLease(for: fixture.id)
        defer { withExtendedLifetime(lease) {} }
        await #expect(throws: EnvironmentStoreError.busy) { try await lifecycle.requestGameUninstall(appID: 42) }
        #expect(await runtime.launches == 0)
        #expect(await runtime.commands.isEmpty)
    }

    @Test("Uninstall refuses prefix replacement before dispatch")
    func uninstallChangedPrefix() async throws {
        let fixture = try await LifecycleFixture(); defer { fixture.remove() }
        _ = try fixture.game()
        let runtime = LifecycleFixtureRuntime()
        let base = await runtime.driver
        _ = try await SteamLifecycle(store: fixture.store, driver: base).launch()
        let prefix = fixture.store.prefixURL(for: fixture.id)
        let driver = SteamLifecycleDriver(preflight: {
            try FileManager.default.moveItem(at: prefix, to: fixture.parent.appendingPathComponent("retained-prefix"))
            try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: false)
        }, observe: base.observe, spawn: base.spawn, execute: base.execute)
        await #expect(throws: EnvironmentStoreError.unsafePath) {
            try await SteamLifecycle(store: fixture.store, driver: driver).requestGameUninstall(appID: 42)
        }
        #expect(await runtime.commands.isEmpty)
    }

    @Test("Satisfactory backend options are scoped to one owned Play request", arguments: ["dxmt", "dxvk", "metal3"])
    func backendLaunchOptions(_ backend: String) async throws {
        let fixture = try await LifecycleFixture(); defer { fixture.remove() }
        let apps = fixture.store.prefixURL(for: fixture.id).appendingPathComponent("drive_c/Program Files (x86)/Steam/steamapps")
        try FileManager.default.createDirectory(at: apps.appendingPathComponent("common/Fixture"), withIntermediateDirectories: true)
        try GameFixtures.renderer.manifest(directory: "Fixture")
            .write(to: apps.appendingPathComponent("appmanifest_\(GameFixtures.renderer.appId).acf"))
        let settings = fixture.store.root.appendingPathComponent("Metadata/GameCompatibility.json")
        let original = try GameFixtures.preferences(game: GameFixtures.renderer, backend: backend)
        try original.write(to: settings)
        let runtime = LifecycleFixtureRuntime()
        let lifecycle = SteamLifecycle(store: fixture.store, driver: await runtime.driver)
        _ = try await lifecycle.launchGame(appID: 526870)
        let commands = await runtime.commands
        #expect(commands.count == 1)
        let args = try #require(commands.first)
        #expect(args.dropFirst().prefix(2) == ["-applaunch", "526870"])
        #expect(Array(args.dropFirst(3)) == (GameFixtures.renderer.launchArguments?[backend] ?? []))
        #expect(GraphicsBackend.dxvk.launchOptions(appID: 553850).isEmpty)
        #expect(try Data(contentsOf: settings) == original)
        let updated = Data("""
        {"schemaVersion":1,"revision":3,"appId":\(GameFixtures.renderer.appId),"name":"\(GameFixtures.renderer.name)","runtime":"sikarugir-10.0_6","launchArguments":{"dxmt":["\(GameFixtures.renderer.option("dx11"))"],"dxvk":["\(GameFixtures.renderer.option("dx11"))"]},"notes":"Updated profile fixture"}
        """.utf8)
        try await GameProfileStore(root: fixture.store.root).accept(updated, appID: 526870)
        _ = try await lifecycle.launchGame(appID: 526870)
        let updatedCommand = try #require(await runtime.commands.last)
        #expect(Array(updatedCommand.dropFirst(3)) == (backend == "metal3" ? [] : [GameFixtures.renderer.option("dx11")]))
        #expect(try Data(contentsOf: settings) == original)
        _ = try await lifecycle.stop()
    }
    @Test("Cloud-blocked launch feedback observes without sending a second Play request")
    func launchFeedbackDoesNotRetry() async throws {
        let fixture = try await LifecycleFixture(); defer { fixture.remove() }
        let steam = fixture.store.prefixURL(for: fixture.id).appendingPathComponent("drive_c/Program Files (x86)/Steam")
        let apps = steam.appendingPathComponent("steamapps")
        try FileManager.default.createDirectory(at: apps.appendingPathComponent("common/Fixture"), withIntermediateDirectories: true)
        try Data(#""AppState" { "appid" "42" "name" "Fixture" "installdir" "Fixture" "StateFlags" "4" }"#.utf8).write(to: apps.appendingPathComponent("appmanifest_42.acf"))
        let logs = steam.appendingPathComponent("logs")
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let log = logs.appendingPathComponent("console_log.txt")
        try Data("[2026-09-18 01:00:00] Game process added : AppID 42 old\n".utf8).write(to: log)
        let runtime = LifecycleFixtureRuntime()
        let lifecycle = SteamLifecycle(store: fixture.store, driver: await runtime.driver)
        let observation = try await lifecycle.launchGame(appID: 42)
        #expect(await observation.poll() == .waitingForSteam)
        let output = try FileHandle(forWritingTo: log)
        try output.seekToEnd()
        try output.write(contentsOf: Data("[2026-09-19 01:00:00] GameAction [AppID 42, ActionID 1] : LaunchApp waiting for user response to SynchronizingCloud \"syncfailed\"\n".utf8))
        try output.close()
        #expect(await observation.poll() == .cloudAttention)
        #expect(await observation.poll() == .cloudAttention)
        #expect(await runtime.commands.count == 1)
        #expect(await runtime.commands.first?.suffix(2) == ["-applaunch", "42"])
        _ = try await lifecycle.stop()
        #expect(await observation.poll() == .unavailable)
    }
    @Test("Stop retries a transient incomplete inventory before control and after graceful exit", arguments: [false, true])
    func transientShutdownObservation(afterShutdown: Bool) async throws {
        let fixture = try await LifecycleFixture(); defer { fixture.remove() }
        let runtime = LifecycleFixtureRuntime()
        let lifecycle = SteamLifecycle(store: fixture.store, driver: await runtime.driver, gracefulTimeout: 0.05)
        _ = try await lifecycle.launch()
        if afterShutdown { await runtime.afterShutdownCompleteness([false, true]) }
        else { await runtime.observeCompleteness([false, true]) }
        #expect(try await lifecycle.stop() == .graceful)
        #expect(await runtime.commands.count == 1)
        #expect(!(await runtime.forced))
        #expect(!(await runtime.signalled))
        #expect(!(try await RuntimeSettingsStore(store: fixture.store).isSelectionLocked()))
    }

    @Test("Persistent incomplete shutdown observations retain ownership and never escalate", arguments: [false, true])
    func unavailableShutdownObservation(afterShutdown: Bool) async throws {
        let fixture = try await LifecycleFixture(); defer { fixture.remove() }
        let runtime = LifecycleFixtureRuntime()
        let lifecycle = SteamLifecycle(store: fixture.store, driver: await runtime.driver, gracefulTimeout: 0.05)
        _ = try await lifecycle.launch()
        if afterShutdown { await runtime.afterShutdownCompleteness(Array(repeating: false, count: 10)) }
        else { await runtime.observeCompleteness(Array(repeating: false, count: 10)) }
        await #expect(throws: SteamLifecycleError.observationUnavailable) { try await lifecycle.stop() }
        #expect(await runtime.commands.count == (afterShutdown ? 1 : 0))
        #expect(!(await runtime.forced))
        #expect(!(await runtime.signalled))
        #expect(try await RuntimeSettingsStore(store: fixture.store).isSelectionLocked())
        if !afterShutdown { #expect(await runtime.observations == 4) }
    }

    @Test("An incomplete snapshot with a foreign process is refused immediately")
    func incompleteForeignShutdown() async throws {
        let fixture = try await LifecycleFixture(); defer { fixture.remove() }
        let runtime = LifecycleFixtureRuntime()
        let lifecycle = SteamLifecycle(store: fixture.store, driver: await runtime.driver)
        _ = try await lifecycle.launch()
        await runtime.foreign()
        await runtime.observeCompleteness([false, true])
        await #expect(throws: SteamLifecycleError.foreignActivity) { try await lifecycle.stop() }
        #expect(await runtime.observations == 1)
        #expect(await runtime.commands.isEmpty)
        #expect(try await RuntimeSettingsStore(store: fixture.store).isSelectionLocked())
    }

    @Test("One observation retry budget covers the entire Stop operation")
    func shutdownRetryBudget() async throws {
        let fixture = try await LifecycleFixture(); defer { fixture.remove() }
        let runtime = LifecycleFixtureRuntime()
        let lifecycle = SteamLifecycle(store: fixture.store, driver: await runtime.driver, gracefulTimeout: 0.05)
        _ = try await lifecycle.launch()
        await runtime.observeCompleteness([false, true, false, true])
        await runtime.afterShutdownCompleteness([false, false, true])
        await #expect(throws: SteamLifecycleError.observationUnavailable) { try await lifecycle.stop() }
        #expect(await runtime.commands.count == 1)
        #expect(await runtime.observations == 6)
        #expect(!(await runtime.forced))
        #expect(try await RuntimeSettingsStore(store: fixture.store).isSelectionLocked())
    }

    @Test("A gap restarts idle confirmation rather than counting unobserved time as quiet")
    func idleObservationGap() async throws {
        let fixture = try await LifecycleFixture(); defer { fixture.remove() }
        let runtime = LifecycleFixtureRuntime()
        let lifecycle = SteamLifecycle(store: fixture.store, driver: await runtime.driver, gracefulTimeout: 0.05)
        _ = try await lifecycle.launch()
        await runtime.handoffGap()
        await runtime.observeCompleteness([true, false, true, true])
        #expect(try await lifecycle.stop() == .alreadyStopped)
        #expect(await runtime.observations == 4)
        #expect(await runtime.commands.isEmpty)
    }

    @Test("Receiptless Stop retries inspection but never adopts a process")
    func receiptlessObservationGap() async throws {
        let fixture = try await LifecycleFixture(); defer { fixture.remove() }
        let runtime = LifecycleFixtureRuntime()
        let lifecycle = SteamLifecycle(store: fixture.store, driver: await runtime.driver)
        await runtime.observeCompleteness([false, true])
        #expect(try await lifecycle.stop() == .alreadyStopped)
        #expect(await runtime.observations == 2)
        await runtime.foreign()
        await runtime.observeCompleteness([false, true])
        await #expect(throws: SteamLifecycleError.foreignActivity) { try await lifecycle.stop() }
        #expect(await runtime.observations == 1)
        #expect(await runtime.commands.isEmpty)
    }

    @Test("Cancelling a Stop retry keeps its receipt and sends no shutdown command")
    func cancelledObservationRetry() async throws {
        let fixture = try await LifecycleFixture(); defer { fixture.remove() }
        let runtime = LifecycleFixtureRuntime()
        let lifecycle = SteamLifecycle(store: fixture.store, driver: await runtime.driver)
        _ = try await lifecycle.launch()
        await runtime.observeCompleteness(Array(repeating: false, count: 10))
        let operation = Task { try await lifecycle.stop() }
        while await runtime.observations == 0 { try await Task.sleep(for: .milliseconds(1)) }
        operation.cancel()
        await #expect(throws: CancellationError.self) { try await operation.value }
        #expect(await runtime.commands.isEmpty)
        #expect(try await RuntimeSettingsStore(store: fixture.store).isSelectionLocked())
    }

    @Test("A prefix replaced during an incomplete inventory cannot be retried or controlled")
    func changedScopeDuringObservation() async throws {
        let fixture = try await LifecycleFixture(); defer { fixture.remove() }
        let runtime = LifecycleFixtureRuntime()
        let original = await runtime.driver
        _ = try await SteamLifecycle(store: fixture.store, driver: original).launch()
        let savedPrefix = fixture.parent.appendingPathComponent("old-prefix")
        let driver = SteamLifecycleDriver(preflight: original.preflight, observe: { _, prefix in
            do {
                try FileManager.default.moveItem(at: prefix, to: savedPrefix)
                try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: false)
            } catch { Issue.record(error) }
            return .init(processes: [], complete: false)
        }, spawn: original.spawn, execute: original.execute)
        let lifecycle = SteamLifecycle(store: fixture.store, driver: driver)
        await #expect(throws: EnvironmentStoreError.unsafePath) { try await lifecycle.stop() }
        #expect(await runtime.commands.isEmpty)
        #expect(FileManager.default.fileExists(atPath: fixture.store.root.appendingPathComponent("Metadata/Lifecycle/steam.json").path))
    }

    @Test("Game launch starts scoped Steam once and revalidates installation before every request")
    func launchInstalledGame() async throws {
        let fixture = try await LifecycleFixture(); defer { fixture.remove() }
        let apps = fixture.store.prefixURL(for: fixture.id).appendingPathComponent("drive_c/Program Files (x86)/Steam/steamapps")
        try FileManager.default.createDirectory(at: apps.appendingPathComponent("common/Stardew Valley"), withIntermediateDirectories: true)
        let manifest = apps.appendingPathComponent("appmanifest_413150.acf")
        try Data(#""AppState" { "appid" "413150" "name" "Stardew Valley" "installdir" "Stardew Valley" "StateFlags" "4" }"#.utf8).write(to: manifest)
        let runtime = LifecycleFixtureRuntime()
        let lifecycle = SteamLifecycle(store: fixture.store, driver: await runtime.driver)
        try await lifecycle.launchGame(appID: 413150)
        #expect(await runtime.launches == 1)
        #expect(await runtime.commands.last?.suffix(2) == ["-applaunch", "413150"])
        try await lifecycle.launchGame(appID: 413150)
        #expect(await runtime.launches == 1)
        await runtime.foreign()
        await #expect(throws: SteamLifecycleError.foreignActivity) { try await lifecycle.launchGame(appID: 413150) }
        #expect(await runtime.commands.count == 2)
        try FileManager.default.removeItem(at: manifest)
        await #expect(throws: SteamGameLibraryError.notInstalled) { try await lifecycle.launchGame(appID: 413150) }
        #expect(await runtime.commands.count == 2)
    }

    @Test("Uninstall during Steam startup prevents the subsequent game command")
    func gameRemovedDuringStartup() async throws {
        let fixture = try await LifecycleFixture(); defer { fixture.remove() }
        let apps = fixture.store.prefixURL(for: fixture.id).appendingPathComponent("drive_c/Program Files (x86)/Steam/steamapps")
        try FileManager.default.createDirectory(at: apps.appendingPathComponent("common/Game"), withIntermediateDirectories: true)
        let manifest = apps.appendingPathComponent("appmanifest_413150.acf")
        try Data(#""AppState" { "appid" "413150" "name" "Game" "installdir" "Game" "StateFlags" "4" }"#.utf8).write(to: manifest)
        let runtime = LifecycleFixtureRuntime()
        let base = await runtime.driver
        let driver = SteamLifecycleDriver(preflight: base.preflight, observe: base.observe, spawn: { request in
            await runtime.spawn(request)
            try FileManager.default.removeItem(at: manifest)
        }, execute: base.execute)
        let lifecycle = SteamLifecycle(store: fixture.store, driver: driver)
        await #expect(throws: SteamGameLibraryError.notInstalled) { try await lifecycle.launchGame(appID: 413150) }
        #expect(await runtime.launches == 1)
        #expect(await runtime.commands.isEmpty)
    }

    @Test("Explicit live cleanup of the recorded managed session", .enabled(if: ProcessInfo.processInfo.environment["GAMEKIT_STOP_ONLY"] == "1"))
    func stopRecordedSession() async throws {
        let store = try EnvironmentStore()
        let lifecycle = SteamLifecycle(store: store, layout: try await RuntimeSettingsStore(store: store).layout())
        let result = try await lifecycle.stop()
        #expect(try await lifecycle.status() == .stopped)
        print("Recorded managed session cleanup: \(result)")
    }

    @Test("Launch is idempotent and a reopened controller restores scoped stop")
    func reopen() async throws {
        let fixture = try await LifecycleFixture(); defer { fixture.remove() }
        let runtime = LifecycleFixtureRuntime()
        let driver = await runtime.driver
        let first = SteamLifecycle(store: fixture.store, driver: driver, gracefulTimeout: 0.05)
        #expect(try await first.status() == .stopped)
        _ = try await first.launch()
        #expect(try await first.launch() == .running)
        #expect(await runtime.launches == 1)
        try await first.show()
        #expect(await runtime.launches == 1)
        let reopened = SteamLifecycle(store: fixture.store, driver: driver, gracefulTimeout: 0.05)
        #expect(try await reopened.status() == .running)
        #expect(try await reopened.stop() == .graceful)
        #expect(try await reopened.status() == .stopped)
        _ = try await reopened.launch()
        #expect(await runtime.launches == 2)
        _ = try await reopened.stop()
    }

    @Test("Graceful timeout forces only the recorded environment")
    func fallback() async throws {
        let fixture = try await LifecycleFixture(); defer { fixture.remove() }
        let runtime = LifecycleFixtureRuntime()
        await runtime.refuseGraceful()
        let lifecycle = SteamLifecycle(store: fixture.store, driver: await runtime.driver, gracefulTimeout: 0.05)
        _ = try await lifecycle.launch()
        #expect(try await lifecycle.stop() == .forced)
        #expect(await runtime.forced)
    }

    @Test("Tagged server survivors reach the final identity-checked fallback")
    func orphanFallback() async throws {
        let fixture = try await LifecycleFixture(); defer { fixture.remove() }
        let runtime = LifecycleFixtureRuntime()
        await runtime.leaveOrphan()
        let lifecycle = SteamLifecycle(store: fixture.store, driver: await runtime.driver, gracefulTimeout: 0.05)
        _ = try await lifecycle.launch()
        #expect(try await lifecycle.stop() == .forced)
        #expect(await runtime.signalled)
        #expect(try await lifecycle.status() == .stopped)
    }

    @Test("Foreign process tags refuse both launch and shutdown")
    func foreignActivity() async throws {
        let fixture = try await LifecycleFixture(); defer { fixture.remove() }
        let runtime = LifecycleFixtureRuntime()
        let lifecycle = SteamLifecycle(store: fixture.store, driver: await runtime.driver)
        _ = try await lifecycle.launch()
        await runtime.foreign()
        #expect(try await lifecycle.status() == .foreignActivity)
        await #expect(throws: SteamLifecycleError.foreignActivity) { try await lifecycle.stop() }
        await #expect(throws: SteamLifecycleError.foreignActivity) { try await lifecycle.launch() }
        #expect(!(await runtime.forced))
    }

    @Test("A short empty handoff retains ownership and does not launch a duplicate")
    func handoffGap() async throws {
        let fixture = try await LifecycleFixture(); defer { fixture.remove() }
        let runtime = LifecycleFixtureRuntime()
        let lifecycle = SteamLifecycle(store: fixture.store, driver: await runtime.driver)
        _ = try await lifecycle.launch()
        await runtime.handoffGap()
        #expect(try await lifecycle.status() == .starting)
        #expect(try await lifecycle.launch() == .starting)
        #expect(await runtime.launches == 1)
    }

    @Test("Replacing a prefix invalidates its persistent control receipt")
    func replacedPrefix() async throws {
        let fixture = try await LifecycleFixture(); defer { fixture.remove() }
        let runtime = LifecycleFixtureRuntime()
        let lifecycle = SteamLifecycle(store: fixture.store, driver: await runtime.driver)
        _ = try await lifecycle.launch()
        let prefix = fixture.store.prefixURL(for: fixture.id)
        try FileManager.default.moveItem(at: prefix, to: fixture.parent.appendingPathComponent("old-prefix"))
        let executable = prefix.appendingPathComponent(RelativePath.steamDefault.rawValue)
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("replacement".utf8).write(to: executable)
        await #expect(throws: SteamLifecycleError.scopeChanged) { try await lifecycle.stop() }
        #expect(!(await runtime.forced))
    }

    @Test("Persistent launch receipts pin runtime selection until scoped Stop completes")
    func selectionPinnedAcrossRestart() async throws {
        let fixture = try await LifecycleFixture(); defer { fixture.remove() }
        let runtime = LifecycleFixtureRuntime()
        let lifecycle = SteamLifecycle(store: fixture.store, driver: await runtime.driver, gracefulTimeout: 0.05)
        _ = try await lifecycle.launch()
        var record = try #require(await fixture.store.load(fixture.id))
        record.installationRecipeVersion = nil
        await #expect(throws: EnvironmentStoreError.busy) { try await fixture.store.save(record) }
        _ = try await lifecycle.stop()
        _ = try await fixture.store.save(record)
    }

    @Test("Missing runtime reports unverified but an already idle receipt can be released safely")
    func runtimeDisappearance() async throws {
        let fixture = try await LifecycleFixture(); defer { fixture.remove() }
        let runtime = LifecycleFixtureRuntime()
        let original = await runtime.driver
        _ = try await SteamLifecycle(store: fixture.store, driver: original).launch()
        await runtime.handoffGap()
        let missing = SteamLifecycleDriver(preflight: { throw RuntimeSessionError.prerequisitesNotReady }, observe: original.observe,
            spawn: original.spawn, execute: original.execute, runtimeAvailable: { false })
        let reopened = SteamLifecycle(store: fixture.store, driver: missing, gracefulTimeout: 0.05)
        #expect(try await reopened.status() == .unverified)
        #expect(try await reopened.stop() == .alreadyStopped)
        #expect(!(await runtime.forced))
        #expect(!(try await RuntimeSettingsStore(store: fixture.store).isSelectionLocked()))
    }

    @Test("Uncaptured output does not depend on an app-owned pipe")
    func discardedOutput() async throws {
        let result = try await ProcessExecutor().run(.init(executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf discarded; printf discarded >&2"], outputMode: .discard))
        #expect(result.termination == .exited(0))
        #expect(result.stdoutBytes == 0 && result.stderrBytes == 0)
    }

    @Test("Real managed Steam survives controller replacement and repeats launch/stop", .enabled(if: ProcessInfo.processInfo.environment["GAMEKIT_LIFECYCLE_SMOKE"] == "1"))
    func liveSteamLifecycle() async throws {
        let store = try EnvironmentStore()
        let record = try #require(await store.load(SteamInstallationRecipe.environmentID))
        try #require(record.installation == .installed)
        let layout = try await RuntimeSettingsStore(store: store).layout()
        let initial = await RuntimeProcessObserver().inspect(record: record, prefix: store.prefixURL(for: record.id), layout: layout)
        try #require(initial.complete && initial.processes.isEmpty, "Close managed Steam and games before this live smoke test")
        for cycle in 1...3 {
            let lifecycle = SteamLifecycle(store: store, layout: layout)
            do {
                _ = try await lifecycle.launch()
                var state = try await lifecycle.status()
                for _ in 0..<120 where state != .running {
                    try await Task.sleep(for: .milliseconds(250)); state = try await lifecycle.status()
                }
                #expect(state == .running)
                try await Task.sleep(for: .seconds(5))
                let reopened = SteamLifecycle(store: store, layout: layout)
                #expect(try await reopened.status() == .running)
                let stopped = try await reopened.stop()
                #expect(try await reopened.status() == .stopped)
                print("Live lifecycle cycle \(cycle): \(stopped), stopped")
            } catch {
                _ = try await lifecycle.stop()
                throw error
            }
        }
    }
}
