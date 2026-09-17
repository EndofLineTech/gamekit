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
        let observeExisting = env["GAMEKIT_E6_OBSERVE_EXISTING"] == "1"
        let maximumSeconds: Double = env["GAMEKIT_TEXT_INPUT_EXPERIMENT"] == nil && !observeExisting ? 90 : 180
        try #require((15...maximumSeconds).contains(seconds))
        try #require(CGPreflightScreenCaptureAccess(), "Grant window-capture permission before this opt-in observation")
        let continueDriverWarning = env["GAMEKIT_E6_CONTINUE_GPU_WARNING"] == "1"
        let confirmEnglish = env["GAMEKIT_E6_CONFIRM_ENGLISH"] == "1"
        let advanceTitle = env["GAMEKIT_E6_ADVANCE_TITLE"] == "1"
        let declineOptionalData = env["GAMEKIT_E6_DECLINE_OPTIONAL_DATA"] == "1"
        let advanceSetupDefaults = env["GAMEKIT_E6_ADVANCE_SETUP_DEFAULTS"] == "1"
        try #require(!continueDriverWarning || (appID == 553850 && CGPreflightPostEventAccess()))
        try #require(!confirmEnglish || (appID == 553850 && CGPreflightPostEventAccess()))
        try #require(!advanceTitle || (appID == 553850 && CGPreflightPostEventAccess()))
        try #require(!declineOptionalData || (appID == 553850 && CGPreflightPostEventAccess()))
        try #require(!advanceSetupDefaults || (appID == 553850 && CGPreflightPostEventAccess()))
        if confirmEnglish || advanceTitle || declineOptionalData || advanceSetupDefaults {
            let tool = try #require(env["GAMEKIT_E6_OCR_TOOL"])
            try #require(tool.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: tool))
        }
        let package = URL(fileURLWithPath: try #require(env["GAMEKIT_E6_PACKAGE"]))
        let destination = URL(fileURLWithPath: try #require(env["GAMEKIT_E6_EVIDENCE"]))
        try #require(!FileManager.default.fileExists(atPath: destination.path))
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let experiment = try HelldiversTextInputExperiment.root()
        try #require(experiment == nil || appID == 553850)
        let store = try EnvironmentStore(root: experiment?.appendingPathComponent("Gamekit") ?? EnvironmentStore.applicationSupportRoot)
        let helper = package.appendingPathComponent("Contents/Frameworks/WineGameIdentity.dylib")
        let layout: RuntimeLayout
        if let experiment { layout = HelldiversTextInputExperiment.layout(root: experiment, helper: helper) }
        else {
            let selected = try await RuntimeSettingsStore(store: store).layout()
            layout = RuntimeLayout(dataRoot: store.root, profile: selected.profile, bundle: selected.bundle, identityHelper: helper)
        }
        try #require(layout.hasGameIdentityHelper)
        let lifecycle = SteamLifecycle(store: store, layout: layout)
        let record = try #require(await store.load(SteamInstallationRecipe.environmentID))
        let prefix = store.prefixURL(for: record.id)
        let library = try SteamGameLibrary.scan(prefix: prefix, steamExecutable: record.steamExecutable)
        let game = try #require(library.games.first { $0.id == appID })
        try #require(game.state == .ready)
        let initial = await RuntimeProcessObserver().inspect(record: record, prefix: prefix, layout: layout)
        try #require(initial.complete && (observeExisting || !initial.processes.contains { $0.role == .other }), "Close other managed games before the observation")
        if observeExisting {
            try #require(try await lifecycle.status() == .running)
            let owned = Set(initial.processes.filter { $0.role == .other }.map(\.identity.pid))
            let otherNames = Set(library.games.filter { $0.id != appID }.map(\.name))
            let names = await MainActor.run {
                NSWorkspace.shared.runningApplications.filter { owned.contains($0.processIdentifier) }.compactMap(\.localizedName)
            }
            try #require(names.contains(game.name) && Set(names).isDisjoint(with: otherNames), "Observe only the game just launched from Gamekit")
        }
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
            if !observeExisting { try await lifecycle.launchGame(appID: appID) }
            struct Receipt: Decodable { let token: UUID }
            let root = try #require(try ManagedDirectory.openRoot(store.root, create: false))
            let receiptData = try #require(try root.directory("Metadata")?.directory("Lifecycle")?.read("steam.json"))
            let token = try JSONDecoder().decode(Receipt.self, from: receiptData).token.uuidString
            activeSession = token
            let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
            var sample = 0
            var continuedDriverWarning = false
            var completedScreenActions = Set<String>()
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
                    if capture.termination == .exited(0) {
                        captured += 1
                        if (confirmEnglish || advanceTitle || declineOptionalData || advanceSetupDefaults) && completedScreenActions.count < 9 {
                            let image = destination.appendingPathComponent("sample-\(sample)-\(index).png")
                            let observations = try await recognize(image, crop: nil)
                            func text(_ observation: ScreenText) -> String {
                                observation.text.lowercased().replacingOccurrences(of: " ", with: "")
                            }
                            let stage = observations.contains(where: { text($0) == "speechlanguage" }) ? "speech" : "text"
                            let language = confirmEnglish && !completedScreenActions.contains(stage) && observations.count <= 10
                                && observations.allSatisfy({ ["english(us)", "confirm", "speechlanguage", "textlanguage"].contains(text($0)) })
                                && observations.contains(where: { text($0) == "english(us)" })
                            let title = advanceTitle && !completedScreenActions.contains("title")
                                && observations.contains(where: { text($0).hasSuffix("voidofliberty") })
                                && observations.contains(where: { text($0) == "pressanybutton" })
                            let optionalData = declineOptionalData && !completedScreenActions.contains("optional data")
                                && Set(["aboutgamedata", "decline", "accept"]).isSubset(of: Set(observations.map(text)))
                            let words = Set(observations.map(text))
                            var defaults: String?
                            if advanceSetupDefaults, words.contains(where: { $0.hasSuffix("setup") }) {
                                if Set(["subtitles", "subtitlemode", "subtitlesize", "texttospeech"]).isSubset(of: words) { defaults = "subtitles" }
                                if Set(["audio", "audiodevice", "mastervolume", "voicechat", "disabled"]).isSubset(of: words) { defaults = "audio" }
                                if words.contains("crossplay") { defaults = "crossplay" }
                                if let seen = defaults, completedScreenActions.contains(seen) { defaults = nil }
                            }
                            if advanceSetupDefaults, !completedScreenActions.contains("account"),
                               words.contains(where: { $0.hasPrefix("accountlinkstatus") }) {
                                // Continue the observed account-status page; never
                                // operate a Link, sign-in, or account-change control.
                                defaults = "account"
                            }
                            if advanceSetupDefaults, !completedScreenActions.contains("brightness"),
                               words.contains("adjustbrightness"),
                               words.contains(where: { $0.contains("theleftsideoftheskullshouldbebarelyvisible") }) {
                                defaults = "brightness"
                            }
                            let action = defaults ?? (optionalData ? "optional data" : (title ? "title" : stage))
                            let label = defaults != nil ? "next" : (optionalData ? "decline" : (title ? "pressanybutton" : "confirm"))
                            var buttonBounds = observations.first(where: { text($0) == label })?.boundingBox
                            if defaults != nil {
                                let cropped = try await recognize(image, crop: defaults == "brightness" ? "brightness" : "next-button")
                                if let found = cropped.first(where: { text($0) == "next" })?.boundingBox {
                                    buttonBounds = found
                                }
                            }
                            if language || title || optionalData || defaults != nil, let buttonBounds {
                                let target = await MainActor.run { () -> (Int32, CGRect)? in
                                    for info in CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? [] {
                                        guard info[kCGWindowNumber as String] as? UInt32 == window,
                                              let pid = info[kCGWindowOwnerPID as String] as? Int32, gamePIDs.contains(pid),
                                              let bounds = info[kCGWindowBounds as String] as? [String: Any],
                                              let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { continue }
                                        return (pid, rect)
                                    }
                                    return nil
                                }
                                if let (pid, rect) = target {
                                    _ = try await ProcessExecutor().run(.init(executable: URL(fileURLWithPath: "/usr/bin/osascript"),
                                        arguments: ["-e", "tell application \"System Events\" to set frontmost of (first application process whose unix id is \(pid)) to true"],
                                        timeout: 5, outputLimit: 1024))
                                    let point = CGPoint(x: rect.minX + rect.width * buttonBounds.midX,
                                                        y: rect.minY + rect.height * (1 - buttonBounds.midY))
                                    CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
                                    try await Task.sleep(for: .milliseconds(300))
                                    CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
                                    try await Task.sleep(for: .milliseconds(150))
                                    CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
                                    completedScreenActions.insert(action)
                                    print("E6 selected \(label) on recognized \(action) screen")
                                }
                            }
                        }
                    }
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

    private struct ScreenText: Decodable {
        let text: String
        let boundingBox: CGRect
    }

    private func recognize(_ image: URL, crop: String?) async throws -> [ScreenText] {
        let tool = try #require(ProcessInfo.processInfo.environment["GAMEKIT_E6_OCR_TOOL"])
        let result = try await ProcessExecutor().run(.init(executable: URL(fileURLWithPath: tool),
            arguments: [image.path] + (crop.map { [$0] } ?? []), timeout: 5, outputLimit: 16384))
        guard result.termination == .exited(0) else {
            print("E6 OCR observation gap; no action taken")
            return []
        }
        return try JSONDecoder().decode([ScreenText].self, from: Data(result.stdoutText.utf8))
    }
}
