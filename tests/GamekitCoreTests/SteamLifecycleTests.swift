import Foundation
import Testing
@testable import GamekitCore

private actor LifecycleFixtureRuntime {
    var token: String?
    var prefix: String?
    var launches = 0
    var forced = false
    var graceful = true
    func foreign() { token = "foreign" }
    func refuseGraceful() { graceful = false }
    func handoffGap() { token = nil }
    func snapshot() -> RuntimeProcessSnapshot {
        .init(processes: token.map { [.init(identity: .init(pid: 123, startSeconds: 1, startMicroseconds: 0), role: .steam, sessionID: $0)] } ?? [], complete: true)
    }
    func spawn(_ request: CommandRequest) {
        launches += 1; token = request.environment["GAMEKIT_SESSION_ID"]
        prefix = request.environment["WINEPREFIX"]
        #expect(request.outputMode == .discard)
        #expect(request.timeout == nil)
    }
    func execute(_ request: CommandRequest) async throws -> CommandResult {
        #expect(prefix != nil && request.environment["WINEPREFIX"] == prefix)
        #expect(request.environment["GAMEKIT_SESSION_ID"] == token)
        if request.arguments == ["-k"] { forced = true; token = nil }
        else if request.arguments.last == "-shutdown", graceful { token = nil }
        return try await ProcessExecutor().run(.init(executable: URL(fileURLWithPath: "/usr/bin/true")))
    }
    var driver: SteamLifecycleDriver {
        .init(preflight: {}, observe: { _, _ in await self.snapshot() }, spawn: { await self.spawn($0) }, execute: { try await self.execute($0) })
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
}

@Suite("Persistent Steam lifecycle")
struct SteamLifecycleTests {
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
        try #require(await store.load(SteamInstallationRecipe.environmentID)?.installation == .installed)
        for cycle in 1...3 {
            let lifecycle = SteamLifecycle(store: store, layout: RuntimeLayout(dataRoot: store.root))
            _ = try await lifecycle.launch()
            var state = try await lifecycle.status()
            for _ in 0..<120 where state != .running {
                try await Task.sleep(for: .milliseconds(250)); state = try await lifecycle.status()
            }
            #expect(state == .running)
            try await Task.sleep(for: .seconds(5))
            let reopened = SteamLifecycle(store: store, layout: RuntimeLayout(dataRoot: store.root))
            #expect(try await reopened.status() == .running)
            let stopped = try await reopened.stop()
            #expect(try await reopened.status() == .stopped)
            print("Live lifecycle cycle \(cycle): \(stopped), stopped")
        }
    }
}
