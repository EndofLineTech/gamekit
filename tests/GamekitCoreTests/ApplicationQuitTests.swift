import AppKit
import CProcessSupport
import Foundation
import Testing
@testable import GamekitCore

@Suite("Application quit and Dock identity")
struct ApplicationQuitTests {
    @Test("Normal Quit and ordinary reopen preserve Steam with one correctly named foreground application", .enabled(if: ProcessInfo.processInfo.environment["GAMEKIT_REAL_QUIT_PROBE"] == "1"))
    func realGamekitQuit() async throws {
        let store = try EnvironmentStore()
        let record = try #require(await store.load(SteamInstallationRecipe.environmentID))
        try #require(record.installation == .installed)
        let layout = RuntimeLayout(dataRoot: store.root)
        let observer = RuntimeProcessObserver()
        let prefix = store.prefixURL(for: record.id)
        let lifecycle = SteamLifecycle(store: store, layout: layout)
        if ProcessInfo.processInfo.environment["GAMEKIT_QUIT_STOP_EXISTING"] == "1" { _ = try await lifecycle.stop() }
        let before = await observer.inspect(record: record, prefix: prefix, layout: layout)
        try #require(before.complete && before.processes.isEmpty, "Start this probe only with managed Steam stopped")
        _ = try await lifecycle.stop() // clear only this idle session's stale receipt
        let quitRequest = CommandRequest(executable: URL(fileURLWithPath: "/usr/bin/osascript"),
            arguments: ["-e", "tell application id \"tech.endofline.gamekit\" to quit"], timeout: 10)
        if !NSRunningApplication.runningApplications(withBundleIdentifier: "tech.endofline.gamekit").isEmpty {
            _ = try await ProcessExecutor().run(quitRequest)
            try await Task.sleep(for: .milliseconds(500))
        }
        let appPath = try #require(ProcessInfo.processInfo.environment["GAMEKIT_APP_PATH"])
        _ = try await ProcessExecutor().run(.init(executable: URL(fileURLWithPath: "/usr/bin/open"), arguments: [appPath, "--args", "--launch-steam"]))
        var running = false
        for _ in 0..<120 {
            if try await lifecycle.status() == .running { running = true; break }
            try await Task.sleep(for: .milliseconds(250))
        }
        try #require(running)
        try await Task.sleep(for: .seconds(30)) // allow Steam/CEF GUI registration
        let live = await observer.inspect(record: record, prefix: prefix, layout: layout)
        try #require(live.complete)
        let ownedPIDs = Set(live.processes.map { $0.identity.pid })
        let foreground = NSWorkspace.shared.runningApplications.filter { ownedPIDs.contains($0.processIdentifier) && $0.activationPolicy == .regular }
        print("Managed Dock applications: \(foreground.map { $0.localizedName ?? "?" })")
        for application in foreground {
            print("Foreground managed PID \(application.processIdentifier), bundle \(application.bundleIdentifier ?? "unbundled")")
        }
        #expect(foreground.count == 1)
        #expect(foreground.allSatisfy { $0.localizedName == "Windows Steam" })
        let parent = try #require(NSRunningApplication.runningApplications(withBundleIdentifier: "tech.endofline.gamekit").first)
        let pid = parent.processIdentifier
        let quit = try await ProcessExecutor().run(quitRequest)
        #expect(quit.termination == .exited(0) && quit.duration < 5)
        try await Task.sleep(for: .seconds(3))
        var identity = GKProcessIdentity()
        let alive = gk_identity(pid, &identity) == 0 && identity.zombie == 0
        print("Normal Quit: duration=\(quit.duration) parentAlive=\(alive) Steam=\(try await lifecycle.status())")
        #expect(!alive)
        let listed = try await ProcessExecutor().run(.init(executable: URL(fileURLWithPath: "/usr/bin/lsappinfo"), arguments: ["list"]))
        let retained = listed.stdoutText.components(separatedBy: "\n").contains { $0.contains("pid = \(pid) ") && $0.contains("exited-with-subordinates") }
        print("Gamekit retained as exited-with-subordinates: \(retained)")
        #expect(!retained)
        _ = try await ProcessExecutor().run(.init(executable: URL(fileURLWithPath: "/usr/bin/open"), arguments: [appPath]))
        try await Task.sleep(for: .seconds(3))
        let reopened = NSRunningApplication.runningApplications(withBundleIdentifier: "tech.endofline.gamekit")
        #expect(reopened.contains { $0.processIdentifier != pid && !$0.isTerminated })
        #expect(try await lifecycle.status() == .running)
        _ = try await lifecycle.stop()
    }
}
