import AppKit
import Foundation
import Testing
@testable import GamekitCore

@Suite("Steam game launch feedback")
struct GameLaunchObservationTests {
    @Test("Observe one approved cold launch without retrying or answering Steam prompts",
          .enabled(if: ProcessInfo.processInfo.environment["GAMEKIT_COLD_LAUNCH_OBSERVATION"] == "1"))
    func liveColdLaunch() async throws {
        let env = ProcessInfo.processInfo.environment
        let appID = try #require(env["GAMEKIT_COLD_LAUNCH_APPID"].flatMap(UInt32.init))
        let helper = URL(fileURLWithPath: try #require(env["GAMEKIT_IDENTITY_X86_HELPER"]))
        let store = try EnvironmentStore()
        let selected = try await RuntimeSettingsStore(store: store).layout()
        let layout = RuntimeLayout(dataRoot: store.root, profile: selected.profile, bundle: selected.bundle,
                                   identityHelper: helper, graphicsBackend: selected.graphicsBackend)
        let lifecycle = SteamLifecycle(store: store, layout: layout)
        try #require(try await lifecycle.status() == .stopped, "Close the existing managed session before this approved test")
        func cleanup() async throws {
            if let snapshot = try? await lifecycle.diagnosticProcesses() {
                let pids = Set(snapshot.processes.filter { $0.role == .other }.map(\.identity.pid))
                await MainActor.run {
                    for app in NSWorkspace.shared.runningApplications where pids.contains(app.processIdentifier) && app.activationPolicy == .regular { _ = app.terminate() }
                }
                try await Task.sleep(for: .seconds(2))
            }
            print("Cold launch observation cleanup: \(try await lifecycle.stop())")
        }
        do {
            let start = ContinuousClock.now
            let observation = try await lifecycle.launchGame(appID: appID)
            print("Cold launch: one request sent at \(start.duration(to: .now))")
            var previous: SteamGameLaunchProgress?
            for _ in 0..<120 {
                let progress = await observation.poll()
                if progress != previous { print("Cold launch +\(start.duration(to: .now)): \(progress.rawValue)"); previous = progress }
                if progress.isTerminal || [.cloudAttention, .otherSessionAttention].contains(progress) { break }
                try await Task.sleep(for: .seconds(1))
            }
            try #require(previous == .processCreated || previous == .cloudAttention || previous == .otherSessionAttention,
                         "Steam acknowledgement was not observed; do not infer a successful launch")
            try await Task.sleep(for: .seconds(5))
        } catch { try await cleanup(); throw error }
        try await cleanup()
    }
    @Test("The observed cold-start incident is Cloud attention, not a dropped request")
    func cloudIncident() {
        var parser = SteamGameLaunchParser(appID: 553850)
        parser.receive(Data("[2026-09-18 17:04:13] GameAction [AppID 553850, ActionID 1] : LaunchApp changed task to SynchronizingCloud with \"\"\n".utf8))
        #expect(parser.progress == .synchronizingCloud)
        parser.receive(Data("[2026-09-18 17:04:15] GameAction [AppID 553850, ActionID 1] : LaunchApp waiting for user response to SynchronizingCloud \"syncfailed\"\n".utf8))
        #expect(parser.progress == .cloudAttention)
        #expect(!parser.progress.isTerminal)
    }

    @Test("Unrelated IDs, partial lines and Completed alone do not prove a game process")
    func strictEvidence() {
        var parser = SteamGameLaunchParser(appID: 42)
        parser.receive(Data("[2026-09-19 01:00:00] Game process added : AppID 420 private args\n".utf8))
        #expect(parser.progress == .waitingForSteam)
        parser.receive(Data("[2026-09-19 01:00:00] GameAction [AppID 42, ActionID 1] : LaunchApp changed task to Completed with \"\"\n".utf8))
        #expect(parser.progress != .processCreated)
        parser.receive(Data("[2026-09-19 01:00:01] Game process added : AppID ".utf8))
        #expect(!parser.progress.isTerminal)
        parser.receive(Data("42 private path and args\n".utf8))
        #expect(parser.progress == .processCreated)
        #expect(!parser.progress.message.contains("private"))
    }

    @Test("Other-session prompts and response transitions are described without choosing for the user")
    func prompts() {
        var parser = SteamGameLaunchParser(appID: 42)
        parser.receive(Data("[2026-09-19 01:00:00] GameAction [AppID 42, ActionID 3] : LaunchApp waiting for user response to KickingOtherSession \"private title\"\n".utf8))
        #expect(parser.progress == .otherSessionAttention)
        parser.receive(Data("[2026-09-19 01:00:01] GameAction [AppID 42, ActionID 3] : LaunchApp continues with user response \"ShowInterstitials\"\n".utf8))
        #expect(parser.progress == .preparing)
    }

    @Test("Observation begins at EOF, refuses rotation/truncation, and never reads historical success")
    func freshness() throws {
        let root = try ManagedDirectory.canonicalRoot(FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("console_log.txt")
        let old = Data("[2026-09-18 01:00:00] Game process added : AppID 42 old\n".utf8)
        try old.write(to: file)
        var tail = try SteamLaunchLogTail(directory: root)
        #expect(try tail.read().isEmpty)
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd(); try handle.write(contentsOf: Data("fresh\n".utf8)); try handle.close()
        #expect(try tail.read() == Data("fresh\n".utf8))
        try Data().write(to: file)
        #expect(throws: (any Error).self) { try tail.read() }
        tail = try SteamLaunchLogTail(directory: root)
        try FileManager.default.moveItem(at: file, to: root.appendingPathComponent("old.log"))
        try old.write(to: file)
        #expect(throws: (any Error).self) { try tail.read() }
    }

    @Test("A redirected log is refused, and missing log creation is bounded")
    func missingAndRedirected() throws {
        let root = try ManagedDirectory.canonicalRoot(FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var tail = try SteamLaunchLogTail(directory: root)
        #expect(try tail.read().isEmpty)
        let file = root.appendingPathComponent("console_log.txt")
        try Data("new\n".utf8).write(to: file)
        #expect(try tail.read() == Data("new\n".utf8))
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: root.appendingPathComponent("outside"))
        #expect(throws: (any Error).self) { try tail.read() }
    }

    @Test("Oversized input is an observation limit, not success")
    func boundedParser() {
        var parser = SteamGameLaunchParser(appID: 42)
        parser.receive(Data(repeating: 65, count: 8193))
        #expect(parser.progress == .unavailable)
    }

    @Test("An observation gap does not consume fresh evidence; lost scope cannot report success")
    func validationGap() async throws {
        let root = try ManagedDirectory.canonicalRoot(FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("console_log.txt")
        try Data().write(to: file)
        let tail = try SteamLaunchLogTail(directory: root)
        actor Validation {
            var count = 0
            func check() throws {
                count += 1
                if count == 2 { throw SteamLifecycleError.observationUnavailable }
            }
        }
        let validation = Validation()
        let observer = SteamGameLaunchObservation(appID: 42, tail: tail, validate: { try await validation.check() })
        try Data("[2026-09-19 01:00:00] Game process added : AppID 42 private\n".utf8).write(to: file)
        #expect(await observer.poll() == .waitingForSteam)
        #expect(await observer.poll() == .processCreated)
        let refused = SteamGameLaunchObservation(appID: 42, tail: tail, validate: { throw SteamLifecycleError.scopeChanged })
        #expect(await refused.poll() == .unavailable)
    }
}
