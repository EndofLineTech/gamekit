import Foundation
import Testing
@testable import GamekitCore

private struct PerformanceFixture {
    let root: URL
    let helper: URL
    let diagnostics: DiagnosticStore
    let target = ScopedRuntimeProcess(identity: .init(pid: 12345, startSeconds: 100, startMicroseconds: 2), role: .other, sessionID: "8E545ED1-C86D-4D9B-A61D-AE1DB9F607AC")
    init(slow: Bool = false) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        helper = root.appendingPathComponent("counter-fixture")
        let script = "#!/bin/sh\nprintf '%s\\n' '{\"event\":\"start\",\"schemaVersion\":1,\"pid\":12345,\"timebase_numer\":125,\"timebase_denom\":3}' '{\"event\":\"sample\",\"pid\":12345}'\n" + (slow ? "/bin/sleep 10\n" : "")
        try Data(script.utf8).write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        diagnostics = try DiagnosticStore(base: root.appendingPathComponent("Logs"))
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
}

@Suite("Bounded performance capture")
struct PerformanceCaptureTests {
    @Test("Stop app debug capture while the same owned game remains alive",
          .enabled(if: ProcessInfo.processInfo.environment["GAMEKIT_DEBUG_LIVE_CANCEL"] == "1"))
    func liveAppCancellation() async throws {
        let env = ProcessInfo.processInfo.environment
        let appID = try #require(env["GAMEKIT_DEBUG_APPID"].flatMap(UInt32.init))
        let app = try #require(env["GAMEKIT_DEBUG_APP"])
        let launchScript = try #require(env["GAMEKIT_DEBUG_LAUNCH_SCRIPT"])
        let store = try EnvironmentStore()
        let layout = try await RuntimeSettingsStore(store: store).layout()
        let lifecycle = SteamLifecycle(store: store, layout: layout)
        let diagnostics = try DiagnosticStore()
        try #require(try await lifecycle.status() == .running, "Start managed Steam and enable debug mode first")
        try #require(try await lifecycle.diagnosticProcesses().processes.allSatisfy { $0.role != .other }, "Close other games first")
        let began = Date()
        do {
            let launched = try await ProcessExecutor().run(.init(executable: URL(fileURLWithPath: "/usr/bin/osascript"),
                arguments: [launchScript, "launch-game-\(appID)"], timeout: 40))
            try #require(launched.termination == .exited(0))
            var captureID: UUID?
            var target: ScopedRuntimeProcess?
            for _ in 0..<120 {
                if let summary = (try? await diagnostics.summaries())?.first(where: { $0.stage == .performanceCapture && $0.startedAt >= began && $0.outcome == nil }) {
                    let output = try await diagnostics.localOutput(summary.id).stdout
                    let rows = String(decoding: output, as: UTF8.self).split(separator: "\n").compactMap {
                        try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
                    }
                    if rows.contains(where: { $0["event"] as? String == "game" && $0["appID"] as? UInt32 == appID }),
                       let pid = rows.first(where: { $0["event"] as? String == "start" })?["pid"] as? Int32 {
                        target = (try? await lifecycle.diagnosticProcesses())?.processes.first { $0.identity.pid == pid && $0.role == .other }
                        if target != nil { captureID = summary.id; break }
                    }
                }
                try await Task.sleep(for: .milliseconds(500))
            }
            let identified = try #require(target), id = try #require(captureID)
            // Reopen the app window if it was hidden/closed while the game took
            // focus. Do not infer game identity from a hardcoded display name.
            let opened = try await ProcessExecutor().run(.init(executable: URL(fileURLWithPath: "/usr/bin/open"), arguments: [app], timeout: 10))
            try #require(opened.termination == .exited(0))
            try await Task.sleep(for: .seconds(2))
            let stopped = try await ProcessExecutor().run(.init(executable: URL(fileURLWithPath: "/usr/bin/osascript"),
                arguments: [launchScript, "stop-debug-capture"], timeout: 40))
            try #require(stopped.termination == .exited(0))
            var cancelled = false
            for _ in 0..<40 {
                cancelled = (try? await diagnostics.summaries())?.first(where: { $0.id == id })?.outcome == .cancelled
                if cancelled { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            try #require(cancelled)
            let after = try await lifecycle.diagnosticProcesses()
            try #require(after.processes.contains { $0.identity == identified.identity && $0.sessionID == identified.sessionID })
            print("Live debug cancellation passed: same owned PID/start identity remains running; cancelled capture=\(id)")
        } catch {
            _ = try await lifecycle.stop()
            throw error
        }
        print("Live debug test cleanup: \(try await lifecycle.stop())")
    }
    @Test("Records counters privately without including them in summary exports")
    func outputAndPrivacy() async throws {
        let fixture = try PerformanceFixture(); defer { fixture.remove() }
        let target = fixture.target
        let capture = GamePerformanceCapture(helper: fixture.helper, diagnostics: fixture.diagnostics,
            observe: { .init(processes: [target], complete: true) })
        let result = try await capture.capture(target: target, appID: 553850, duration: 1)
        #expect(result.samples == 1)
        #expect(try await fixture.diagnostics.localOutput(result.id).stdout.count > 0)
        let summary = String(decoding: try await fixture.diagnostics.exportSummary(result.id), as: UTF8.self)
        #expect(!summary.contains("\"pid\""))
        #expect(!summary.contains("\"appID\""))
        #expect(summary.contains("performanceCapture"))
    }

    @Test("Incomplete or replaced process identities never start a capture", arguments: [false, true])
    func rejectsUnowned(complete: Bool) async throws {
        let fixture = try PerformanceFixture(); defer { fixture.remove() }
        let changed = ScopedRuntimeProcess(identity: .init(pid: 12345, startSeconds: 101, startMicroseconds: 2), role: .other, sessionID: fixture.target.sessionID)
        let capture = GamePerformanceCapture(helper: fixture.helper, diagnostics: fixture.diagnostics,
            observe: { .init(processes: [changed], complete: complete) })
        await #expect(throws: PerformanceCaptureError.scopeChanged) {
            try await capture.capture(target: fixture.target, appID: 553850, duration: 1)
        }
        #expect(try await fixture.diagnostics.summaries().isEmpty)
    }

    @Test("Cancellation stops the sampler and retains an explicit cancelled record")
    func cancellation() async throws {
        let fixture = try PerformanceFixture(slow: true); defer { fixture.remove() }
        let game = try await ProcessExecutor().start(.init(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["10"], timeout: 12))
        defer { game.cancel() }
        let target = ScopedRuntimeProcess(identity: .init(pid: game.pid, startSeconds: 100, startMicroseconds: 2), role: .other, sessionID: fixture.target.sessionID)
        let capture = GamePerformanceCapture(helper: fixture.helper, diagnostics: fixture.diagnostics,
            observe: { .init(processes: [target], complete: true) })
        let task = Task { try await capture.capture(target: target, appID: 553850, duration: 1) }
        for _ in 0..<100 {
            if try await fixture.diagnostics.summaries().first?.stdoutBytes ?? 0 > 0 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(try await fixture.diagnostics.summaries().count == 1)
        let stoppedAt = ContinuousClock.now
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(stoppedAt.duration(to: .now) < .seconds(3))
        #expect(await game.observedLeaderExit() == nil, "Cancelling debug capture must not terminate the observed process")
        game.cancel(); _ = await game.result()
        let summaries = try await fixture.diagnostics.summaries()
        #expect(summaries.count == 1 && summaries.first?.outcome == .cancelled)
    }

    @Test("Loss of session ownership during capture stops only the sampler")
    func ownershipChanges() async throws {
        let fixture = try PerformanceFixture(slow: true); defer { fixture.remove() }
        actor Observer {
            var calls = 0
            func snapshot(_ target: ScopedRuntimeProcess) -> RuntimeProcessSnapshot {
                calls += 1
                return .init(processes: calls == 1 ? [target] : [], complete: true)
            }
        }
        let observer = Observer(), target = fixture.target
        let capture = GamePerformanceCapture(helper: fixture.helper, diagnostics: fixture.diagnostics,
            observe: { await observer.snapshot(target) })
        await #expect(throws: PerformanceCaptureError.scopeChanged) {
            try await capture.capture(target: target, appID: 553850, duration: 1)
        }
        #expect(try await fixture.diagnostics.summaries().first?.outcome == .executionFailed)
    }
}
