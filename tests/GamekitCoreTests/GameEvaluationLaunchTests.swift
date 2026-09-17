import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import GamekitCore

/// A bounded observation run, not a gameplay-success assertion. Captures stay in
/// a private local directory; screenshots and raw window titles are not exported.
@Suite("Opt-in E6 bounded launch observation")
struct GameEvaluationLaunchTests {
    @Test("Observe an approved installed game and close its managed session",
          .enabled(if: ProcessInfo.processInfo.environment["GAMEKIT_E6_OBSERVE_LAUNCH"] == "1"))
    func observeLaunch() async throws {
        let env = ProcessInfo.processInfo.environment
        let rawID = try #require(env["GAMEKIT_E6_APPID"])
        let appID = try #require(UInt32(rawID))
        try #require([553850, 413150].contains(appID))
        let seconds = Double(env["GAMEKIT_E6_OBSERVE_SECONDS"] ?? "45") ?? 45
        try #require((15...90).contains(seconds))
        try #require(CGPreflightScreenCaptureAccess(), "Grant window-capture permission before this opt-in observation")
        let continueDriverWarning = env["GAMEKIT_E6_CONTINUE_GPU_WARNING"] == "1"
        try #require(!continueDriverWarning || (appID == 553850 && CGPreflightPostEventAccess()))
        let package = URL(fileURLWithPath: try #require(env["GAMEKIT_E6_PACKAGE"]))
        let destination = URL(fileURLWithPath: try #require(env["GAMEKIT_E6_EVIDENCE"]))
        try #require(!FileManager.default.fileExists(atPath: destination.path))
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let store = try EnvironmentStore()
        let selected = try await RuntimeSettingsStore(store: store).layout()
        let layout = RuntimeLayout(dataRoot: store.root, bundle: selected.bundle,
            identityHelper: package.appendingPathComponent("Contents/Frameworks/WineGameIdentity.dylib"))
        try #require(layout.hasGameIdentityHelper)
        let lifecycle = SteamLifecycle(store: store, layout: layout)
        let record = try #require(await store.load(SteamInstallationRecipe.environmentID))
        let prefix = store.prefixURL(for: record.id)
        let game = try #require(try SteamGameLibrary.scan(prefix: prefix, steamExecutable: record.steamExecutable).games.first { $0.id == appID })
        try #require(game.state == .ready)
        let initial = await RuntimeProcessObserver().inspect(record: record, prefix: prefix, layout: layout)
        try #require(initial.complete && !initial.processes.contains { $0.role == .other }, "Close other managed games before the observation")
        var activeSession: String?

        func cleanup() async throws {
            let snapshot = await RuntimeProcessObserver().inspect(record: record, prefix: prefix, layout: layout)
            if snapshot.complete, let token = activeSession {
                let pids = Set(snapshot.processes.filter { $0.role == .other && $0.sessionID == token }.map(\.identity.pid))
                await MainActor.run {
                    for app in NSWorkspace.shared.runningApplications where pids.contains(app.processIdentifier) && app.activationPolicy == .regular {
                        _ = app.terminate()
                    }
                }
                try await Task.sleep(for: .seconds(2))
            }
            let result = try await lifecycle.stop()
            #expect(try await lifecycle.status() == .stopped)
            print("E6 cleanup: \(result); managed session stopped")
        }

        do {
            print("E6 AppID=\(appID), build=\(game.buildID ?? "unknown"), observation=\(Int(seconds))s")
            try await lifecycle.launchGame(appID: appID)
            struct Receipt: Decodable { let token: UUID }
            let root = try #require(try ManagedDirectory.openRoot(store.root, create: false))
            let receiptData = try #require(try root.directory("Metadata")?.directory("Lifecycle")?.read("steam.json"))
            let token = try JSONDecoder().decode(Receipt.self, from: receiptData).token.uuidString
            activeSession = token
            let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
            var sample = 0
            var continuedDriverWarning = false
            repeat {
                try await Task.sleep(for: .seconds(10))
                let snapshot = await RuntimeProcessObserver().inspect(record: record, prefix: prefix, layout: layout)
                try #require(snapshot.complete && snapshot.processes.allSatisfy { $0.sessionID == token }, "An observation must remain in the owned session")
                let gamePIDs = Set(snapshot.processes.filter { $0.role == .other }.map(\.identity.pid))
                let foregroundPID = await MainActor.run {
                    NSWorkspace.shared.runningApplications.first(where: {
                        gamePIDs.contains($0.processIdentifier) && $0.activationPolicy == .regular && $0.localizedName == game.name
                    })?.processIdentifier
                }
                if let foregroundPID {
                    _ = try await ProcessExecutor().run(.init(executable: URL(fileURLWithPath: "/usr/bin/osascript"),
                        arguments: ["-e", "tell application \"System Events\" to set frontmost of (first application process whose unix id is \(foregroundPID)) to true"],
                        timeout: 5, outputLimit: 1024))
                }
                try await Task.sleep(for: .milliseconds(500))
                if continueDriverWarning && !continuedDriverWarning {
                    let warning = await MainActor.run { () -> (Int32, CGRect)? in
                        for window in CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? [] {
                            guard let pid = window[kCGWindowOwnerPID as String] as? Int32, gamePIDs.contains(pid),
                                  window[kCGWindowName as String] as? String == "GPU drivers are out of date",
                                  let bounds = window[kCGWindowBounds as String] as? [String: Any],
                                  let rectangle = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                                  rectangle.width >= 300, rectangle.width <= 1200,
                                  rectangle.height >= 120, rectangle.height <= 600 else { continue }
                            return (pid, rectangle)
                        }
                        return nil
                    }
                    if let (pid, bounds) = warning {
                        _ = try await ProcessExecutor().run(.init(executable: URL(fileURLWithPath: "/usr/bin/osascript"),
                            arguments: ["-e", "tell application \"System Events\" to set frontmost of (first application process whose unix id is \(pid)) to true"],
                            timeout: 5, outputLimit: 1024))
                        // Coordinates are relative to the exact observed Windows
                        // warning, excluding the screenshot's shadow padding.
                        let point = CGPoint(x: bounds.minX + bounds.width * 0.806, y: bounds.minY + bounds.height * 0.866)
                        CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
                        try await Task.sleep(for: .milliseconds(300))
                        CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
                        try await Task.sleep(for: .milliseconds(150))
                        CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
                        continuedDriverWarning = true
                        print("E6 selected Continue on the exact Helldivers GPU-driver warning")
                        try await Task.sleep(for: .seconds(1))
                    }
                }
                let pids = Set(snapshot.processes.filter { $0.role == .other || $0.role == .steamUI }.map(\.identity.pid))
                let windows = await MainActor.run {
                    (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []).compactMap { window -> UInt32? in
                        guard let pid = window[kCGWindowOwnerPID as String] as? Int32, pids.contains(pid),
                              let bounds = window[kCGWindowBounds as String] as? [String: Any],
                              let rectangle = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                              rectangle.width > 100, rectangle.height > 60 else { return nil }
                        return window[kCGWindowNumber as String] as? UInt32
                    }
                }
                var captured = 0
                for (index, window) in windows.prefix(6).enumerated() {
                    let capture = try await ProcessExecutor().run(.init(executable: URL(fileURLWithPath: "/usr/sbin/screencapture"),
                        arguments: ["-x", "-o", "-l", String(window), destination.appendingPathComponent("sample-\(sample)-\(index).png").path],
                        timeout: 5, outputLimit: 1024))
                    // A window can close between enumeration and capture. That
                    // is an observation gap, not a game-compatibility assertion.
                    if capture.termination == .exited(0) { captured += 1 }
                }
                print("E6 sample \(sample): owned game/service processes=\(snapshot.processes.filter { $0.role == .other }.count), captured windows=\(captured)")
                sample += 1
            } while ContinuousClock.now < deadline
        } catch {
            try await cleanup()
            throw error
        }
        try await cleanup()
    }
}
