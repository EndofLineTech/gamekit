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
        try #require([553850, 413150, 526870].contains(appID))
        let satisfactoryD3D11 = env["GAMEKIT_E6_SATISFACTORY_D3D11"] == "1"
        try #require(!satisfactoryD3D11 || appID == 526870)
        let sandbox = env["GAMEKIT_E6_SATISFACTORY_USER_DIR"]
        if let sandbox {
            try #require(satisfactoryD3D11 && sandbox.hasPrefix("/") && !sandbox.contains(where: { $0.isWhitespace }))
            _ = try #require(try ManagedDirectory.openRoot(URL(fileURLWithPath: sandbox), create: false))
        }
        let sandboxContinue = env["GAMEKIT_E6_SANDBOX_CONTINUE"] == "1"
        try #require(!sandboxContinue || (sandbox != nil && env["GAMEKIT_SATISFACTORY_PERFORMANCE"] == "1" && CGPreflightPostEventAccess()))
        let guardLog = env["GAMEKIT_SAVE_GUARD_LOG_FILE"].map { URL(fileURLWithPath: $0) }
        try #require(!sandboxContinue || guardLog != nil)
        let sampleSatisfactory = env["GAMEKIT_E6_SAMPLE_SATISFACTORY"] == "1"
        try #require(!sampleSatisfactory || sandbox != nil)
        let disableOcclusion = env["GAMEKIT_E6_DISABLE_OCCLUSION"] == "1"
        try #require(!disableOcclusion || sandbox != nil)
        let helldiversD3D11 = env["GAMEKIT_E6_HELLDIVERS_D3D11"] == "1"
        try #require(!helldiversD3D11 || (appID == 553850 && env["GAMEKIT_E6_UI_LAUNCH_SCRIPT"] == nil && !satisfactoryD3D11))
        let disableStreamline = env["GAMEKIT_E6_DISABLE_STREAMLINE"] == "1"
        try #require(!disableStreamline || satisfactoryD3D11)
        let preferComputePost = env["GAMEKIT_E6_PREFER_COMPUTE_POST"] == "1"
        try #require(!preferComputePost || satisfactoryD3D11)
        let expectMoltenVKPairing = env["GAMEKIT_E6_EXPECT_MOLTENVK_CX"] == "1"
        try #require(!expectMoltenVKPairing || satisfactoryD3D11)
        let expectedMoltenVKLibrary = env["GAMEKIT_E6_EXPECT_MOLTENVK_LIBRARY"]
        try #require(expectedMoltenVKLibrary == nil || (satisfactoryD3D11 && expectedMoltenVKLibrary!.hasPrefix("/")))
        let seconds = Double(env["GAMEKIT_E6_OBSERVE_SECONDS"] ?? "45") ?? 45
        let observeExisting = env["GAMEKIT_E6_OBSERVE_EXISTING"] == "1"
        let maximumSeconds: Double = env["GAMEKIT_TEXT_INPUT_EXPERIMENT"] == nil && !observeExisting && !satisfactoryD3D11 ? 90 : 180
        try #require((15...maximumSeconds).contains(seconds))
        try #require(CGPreflightScreenCaptureAccess(), "Grant window-capture permission before this opt-in observation")
        let tryAgainDriverWarning = env["GAMEKIT_E6_TRY_AGAIN_GPU_WARNING"] == "1"
        try #require(!tryAgainDriverWarning || env["GAMEKIT_E6_CONTINUE_GPU_WARNING"] != "1")
        let continueDriverWarning = env["GAMEKIT_E6_CONTINUE_GPU_WARNING"] == "1" || tryAgainDriverWarning
        let passiveAfterWarning = env["GAMEKIT_E6_PASSIVE_AFTER_WARNING"] == "1"
        let profileStartup = env["GAMEKIT_E6_PROFILE_STARTUP"] == "1"
        let countersOnly = env["GAMEKIT_E6_COUNTERS_ONLY"] == "1"
        let visualTool = env["GAMEKIT_E6_VISUAL_TOOL"]
        if let visualTool {
            try #require(profileStartup && visualTool.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: visualTool))
        }
        try #require(!countersOnly || profileStartup)
        try #require(!profileStartup || (passiveAfterWarning && seconds >= 90))
        if profileStartup {
            let counter = try #require(env["GAMEKIT_E6_COUNTER_TOOL"])
            try #require(counter.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: counter))
        }
        try #require(!passiveAfterWarning || (appID == 553850 && continueDriverWarning))
        let confirmEnglish = env["GAMEKIT_E6_CONFIRM_ENGLISH"] == "1"
        let advanceTitle = env["GAMEKIT_E6_ADVANCE_TITLE"] == "1"
        let declineOptionalData = env["GAMEKIT_E6_DECLINE_OPTIONAL_DATA"] == "1"
        let advanceSetupDefaults = env["GAMEKIT_E6_ADVANCE_SETUP_DEFAULTS"] == "1"
        let spaceRoundTrip = env["GAMEKIT_E6_SPACE_ROUND_TRIP"] == "1"
        try #require(!passiveAfterWarning || !(confirmEnglish || advanceTitle || declineOptionalData || advanceSetupDefaults || spaceRoundTrip))
        let spaceHost = env["GAMEKIT_E6_SPACE_HOST"] == "1"
        let quitWithSpace = env["GAMEKIT_E6_QUIT_WITH_SPACE"] == "1"
        try #require(!quitWithSpace || spaceHost)
        let expectNoSpaceHost = env["GAMEKIT_E6_EXPECT_NO_SPACE_HOST"] == "1"
        try #require(!(passiveAfterWarning && expectNoSpaceHost))
        try #require(!expectNoSpaceHost || !spaceRoundTrip)
        try #require(!spaceHost || spaceRoundTrip)
        try #require(!spaceRoundTrip || (appID == 553850 && seconds >= 90 && CGPreflightPostEventAccess()))
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
        let driverExperiment = try DriverVersionExperiment.root()
        let verifyDriverWarning = driverExperiment != nil || env["GAMEKIT_E6_VERIFY_DRIVER_WARNING_ABSENT"] == "1"
        try #require(!verifyDriverWarning || (appID == 553850 && !continueDriverWarning))
        try #require(driverExperiment == nil || (experiment == nil && appID == 553850 && !continueDriverWarning))
        try #require(experiment == nil || appID == 553850)
        let store = try EnvironmentStore(root: (driverExperiment ?? experiment)?.appendingPathComponent("Gamekit") ?? EnvironmentStore.applicationSupportRoot)
        let helper = package.appendingPathComponent("Contents/Frameworks/WineGameIdentity.dylib")
        let layout: RuntimeLayout
        if let driverExperiment { layout = try DriverVersionExperiment.layout(root: driverExperiment, helper: helper) }
        else if let experiment { layout = HelldiversTextInputExperiment.layout(root: experiment, helper: helper) }
        else {
            let selected = try await RuntimeSettingsStore(store: store).layout()
            layout = RuntimeLayout(dataRoot: store.root, profile: selected.profile, bundle: selected.bundle,
                identityHelper: helper, graphicsBackend: selected.graphicsBackend)
        }
        try #require(layout.hasGameIdentityHelper)
        let lifecycle = SteamLifecycle(store: store, layout: layout)
        let record = try #require(await store.load(SteamInstallationRecipe.environmentID))
        let prefix = store.prefixURL(for: record.id)
        let library = try SteamGameLibrary.scan(prefix: prefix, steamExecutable: record.steamExecutable)
        let game = try #require(library.games.first { $0.id == appID })
        let expectedGameBundle = try SteamApplicationBundle.configured(layout: layout, game: .init(appID: game.id, name: game.name)).bundleURL.path
        try #require(game.state == .ready)
        let initial = await RuntimeProcessObserver().inspect(record: record, prefix: prefix, layout: layout)
        try #require(initial.complete && (observeExisting || !initial.processes.contains { $0.role == .other }), "Close other managed games before the observation")
        let warningSettings = env["GAMEKIT_E6_WARNING_SETTINGS"].map { URL(fileURLWithPath: $0) }
        if let warningSettings {
            try Data(contentsOf: warningSettings).write(to: destination.appendingPathComponent("settings-before.config"), options: .atomic)
        }
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
        var warningWatch: Task<[String], Never>?
        var cpuProfile: Task<Void, Error>?
        var counters: Task<Void, Error>?
        var visual: Task<Void, Error>?

        func cleanup() async throws {
            cpuProfile?.cancel(); counters?.cancel(); visual?.cancel()
            _ = try? await visual?.value
            _ = try? await cpuProfile?.value
            _ = try? await counters?.value
            warningWatch?.cancel()
            if let warningWatch {
                let observations = await warningWatch.value
                try JSONEncoder().encode(observations).write(to: destination.appendingPathComponent("driver-warning-observations.json"), options: .atomic)
                print("E6 driver trial warning observations at 100ms polling: \(observations.count)")
                #expect(observations.isEmpty, "Driver warning appeared; trial did not suppress it")
            }
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
            if quitWithSpace { #expect(result != .forced, "Normal game quit with a Space host must not need forced cleanup") }
            print("E6 cleanup: \(result); managed session stopped")
            if let warningSettings {
                try Data(contentsOf: warningSettings).write(to: destination.appendingPathComponent("settings-after.config"), options: .atomic)
            }
        }

        do {
            if verifyDriverWarning {
                warningWatch = Task { @MainActor in
                    var observations: [String] = []
                    let limit = ContinuousClock.now.advanced(by: .seconds(seconds + 40))
                    while !Task.isCancelled && ContinuousClock.now < limit {
                        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
                        for window in windows {
                            guard window[kCGWindowName as String] as? String == "GPU drivers are out of date",
                                  let pid = window[kCGWindowOwnerPID as String] as? Int32,
                                  NSRunningApplication(processIdentifier: pid)?.localizedName == game.name else { continue }
                            if observations.count < 1200 { observations.append("\(Date().timeIntervalSince1970) pid=\(pid)") }
                        }
                        do { try await Task.sleep(for: .milliseconds(100)) } catch { break }
                    }
                    return observations
                }
            }
            print("E6 AppID=\(appID), build=\(game.buildID ?? "unknown"), observation=\(Int(seconds))s")
            if !observeExisting {
                if let script = env["GAMEKIT_E6_UI_LAUNCH_SCRIPT"] {
                    try #require(driverExperiment == nil && [553850, 526870].contains(appID) && script.hasPrefix("/"))
                    let pressed = try await ProcessExecutor().run(.init(executable: URL(fileURLWithPath: "/usr/bin/osascript"),
                        arguments: [script, "launch-game-\(appID)"], timeout: 40, outputLimit: 4096))
                    print(pressed.stdoutText)
                    try #require(pressed.termination == .exited(0))
                    try await Task.sleep(for: .seconds(8))
                } else if env["GAMEKIT_E6_STEAM_URL_LAUNCH"] == "1" || satisfactoryD3D11 || helldiversD3D11 {
                    _ = try await lifecycle.launch()
                    let observed = try await lifecycle.diagnosticProcesses()
                    let sessions = Set(observed.processes.compactMap(\.sessionID))
                    try #require(sessions.count == 1)
                    let session = try #require(sessions.first)
                    let steam = prefix.appendingPathComponent(record.steamExecutable.rawValue)
                    let launched = try await ProcessExecutor().run(.init(executable: layout.wine,
                        arguments: helldiversD3D11 ? [steam.path, "-applaunch", String(appID), "--use-d3d11"] : satisfactoryD3D11 ? [steam.path, "-applaunch", String(appID), "-dx11"] +
                            (disableStreamline ? ["-ini:Engine:[SystemSettings]:r.Streamline.InitializePlugin=0"] : []) +
                            (preferComputePost ? ["-ini:Engine:[SystemSettings]:r.PostProcessing.PreferCompute=1"] : []) +
                            (disableOcclusion ? ["-ini:Engine:[SystemSettings]:r.AllowOcclusionQueries=0"] : []) +
                            (sandbox.map { ["-UserDir=Z:" + $0] } ?? []) : [steam.path, "steam://rungameid/\(appID)"],
                        environment: layout.environment(prefix: prefix, session: session),
                        workingDirectory: steam.deletingLastPathComponent(), timeout: 10, outputLimit: 8192))
                    try #require(launched.termination == .exited(0))
                    print("E6 launch requested directly through the owned Steam client URL handler")
                } else { try await lifecycle.launchGame(appID: appID) }
            }
            struct Receipt: Decodable { let token: UUID }
            let root = try #require(try ManagedDirectory.openRoot(store.root, create: false))
            let receiptData = try #require(try root.directory("Metadata")?.directory("Lifecycle")?.read("steam.json"))
            let token = try JSONDecoder().decode(Receipt.self, from: receiptData).token.uuidString
            activeSession = token
            let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
            var sample = 0
            var continuedDriverWarning = false
            var completedScreenActions = Set<String>()
            var completedSpaceRoundTrip = false
            var mappedPIDs = Set<Int32>()
            var guardedPIDs = Set<Int32>()
            var verifiedMoltenVKPairing = false
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
                if sandboxContinue, let foregroundPID, let guardLog, !guardedPIDs.contains(foregroundPID),
                   let guardDirectory = try ManagedDirectory.openRoot(guardLog.deletingLastPathComponent(), create: false),
                   let bytes = try guardDirectory.read(guardLog.lastPathComponent, maximumBytes: 65536),
                   String(decoding: bytes, as: UTF8.self).contains("pid=\(foregroundPID) session=\(token) verified=1 ") {
                    guardedPIDs.insert(foregroundPID)
                    print("Verified save-write guard receipt for the current owned game/session")
                }
                if (satisfactoryD3D11 || helldiversD3D11), sample >= (helldiversD3D11 ? 1 : 5), let foregroundPID, !mappedPIDs.contains(foregroundPID) {
                    let maps = try await ProcessExecutor().run(.init(executable: URL(fileURLWithPath: "/usr/bin/vmmap"),
                        arguments: ["-w", String(foregroundPID)], timeout: 10, outputLimit: 4 * 1024 * 1024))
                    if maps.termination == .exited(0) {
                        try maps.stdout.write(to: destination.appendingPathComponent("modules-\(foregroundPID).txt"))
                        if maps.stdoutText.contains(expectedMoltenVKLibrary ?? "/moltenvkcx/libMoltenVK.dylib") &&
                            maps.stdoutText.contains(expectedGameBundle + "/Contents/lib/wine/x86_64-windows/d3d11.dll") {
                            verifiedMoltenVKPairing = true
                            print("E6 verified DXVK game loader and expected MoltenVK mapped in owned game PID=\(foregroundPID)")
                        }
                        mappedPIDs.insert(foregroundPID)
                    }
                }
                if sampleSatisfactory, [7, 10].contains(sample), let foregroundPID {
                    let captured = try await ProcessExecutor().run(.init(executable: URL(fileURLWithPath: "/usr/bin/sample"),
                        arguments: [String(foregroundPID), "5", "10", "-file", destination.appendingPathComponent("cpu-\(sample).txt").path],
                        timeout: 20, outputLimit: 8192))
                    print("Satisfactory diagnostic CPU sample \(sample): \(captured.termination); sampling perturbs timing")
                }
                if let foregroundPID, !verifyDriverWarning, !(passiveAfterWarning && continuedDriverWarning) {
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
                        let point = CGPoint(x: bounds.minX + bounds.width * (tryAgainDriverWarning ? 0.507 : 0.806), y: bounds.minY + bounds.height * 0.866)
                        CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
                        try await Task.sleep(for: .milliseconds(300))
                        CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
                        try await Task.sleep(for: .milliseconds(150))
                        CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
                        continuedDriverWarning = true
                        print("E6 selected \(tryAgainDriverWarning ? "Try Again" : "Continue") once on the exact Helldivers GPU-driver warning")
                        try await Task.sleep(for: .seconds(1))
                    }
                }
                if profileStartup && continuedDriverWarning && counters == nil, let foregroundPID,
                   let process = snapshot.processes.first(where: { $0.identity.pid == foregroundPID }) {
                    let identity = process.identity
                    if let visualTool {
                        visual = Task {
                            let result = try await ProcessExecutor().run(.init(executable: URL(fileURLWithPath: visualTool),
                                arguments: [String(identity.pid), destination.path], timeout: 88, outputLimit: 8192))
                            try (result.stdout + result.stderr).write(to: destination.appendingPathComponent("visual-command.txt"), options: .atomic)
                            guard result.termination == .exited(0) else { throw SteamLifecycleError.observationUnavailable }
                        }
                    }
                    cpuProfile = countersOnly ? nil : Task {
                        for index in 0..<2 {
                            try Task.checkCancellation()
                            let fresh = await RuntimeProcessObserver().inspect(record: record, prefix: prefix, layout: layout)
                            guard fresh.complete else { throw SteamLifecycleError.observationUnavailable }
                            guard fresh.processes.contains(where: { $0.identity == identity && $0.sessionID == token }) else { return }
                            let started = Date().timeIntervalSince1970
                            let result = try await ProcessExecutor().run(.init(executable: URL(fileURLWithPath: "/usr/bin/sample"),
                                arguments: [String(identity.pid), "8", "10", "-file", destination.appendingPathComponent("cpu-\(index).txt").path],
                                timeout: 30, outputLimit: 8192))
                            print("E6 CPU sample \(index): start=\(started) end=\(Date().timeIntervalSince1970) result=\(result.termination)")
                            try (result.stdout + result.stderr).write(to: destination.appendingPathComponent("cpu-\(index)-command.txt"), options: .atomic)
                            guard result.termination == .exited(0) else { throw SteamLifecycleError.observationUnavailable }
                        }
                    }
                    let tool = try #require(env["GAMEKIT_E6_COUNTER_TOOL"])
                    counters = Task {
                        let result = try await ProcessExecutor().run(.init(executable: URL(fileURLWithPath: tool),
                            arguments: [String(identity.pid), String(identity.startSeconds), String(identity.startMicroseconds), "60"],
                            timeout: 70, outputLimit: 262144))
                        try result.stdout.write(to: destination.appendingPathComponent("counters.jsonl"), options: .atomic)
                        try result.stderr.write(to: destination.appendingPathComponent("counter-errors.txt"), options: .atomic)
                        guard result.termination == .exited(0), result.stdoutBytes <= 262144 else { throw SteamLifecycleError.observationUnavailable }
                    }
                }
                if passiveAfterWarning && continuedDriverWarning {
                    print("E6 passive sample \(sample): owned game/service processes=\(snapshot.processes.filter { $0.role == .other }.count); no loop capture or focus action; visual task requested=\(visualTool != nil)")
                    sample += 1
                    continue
                }
                let pids = Set(snapshot.processes.filter { $0.role == .other || $0.role == .steamUI }.map(\.identity.pid))
                if expectNoSpaceHost {
                    let unexpected = await MainActor.run {
                        (CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] ?? []).contains {
                            guard let pid = $0[kCGWindowOwnerPID as String] as? Int32, pids.contains(pid) else { return false }
                            return $0[kCGWindowName as String] as? String == "Gamekit fullscreen Space"
                        }
                    }
                    try #require(!unexpected, "Desktop fullscreen must not create a native Space host")
                }
                if spaceRoundTrip && sample >= 6 && !completedSpaceRoundTrip, let foregroundPID {
                    func script(_ source: String) async throws -> String {
                        let result = try await ProcessExecutor().run(.init(executable: URL(fileURLWithPath: "/usr/bin/osascript"),
                            arguments: ["-e", source], timeout: 5, outputLimit: 1024))
                        guard result.termination == .exited(0) else { throw SteamLifecycleError.observationUnavailable }
                        return result.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                    let target = "tell application \"System Events\" to tell (first application process whose unix id is \(foregroundPID)) "
                    let nativeWindow = spaceHost ? "(first window whose name is \"Gamekit fullscreen Space\")" : "window 1"
                    try #require(try await script(target + "to get value of attribute \"AXFullScreen\" of " + nativeWindow) == "true")
                    _ = try await script("tell application \"Finder\" to activate")
                    try await Task.sleep(for: .seconds(2))
                    _ = try await script(target + "to set frontmost to true")
                    try await Task.sleep(for: .seconds(2))
                    _ = try await script("tell application \"System Events\" to key code 48 using {command down}")
                    try await Task.sleep(for: .seconds(3))
                    let away = await MainActor.run { NSWorkspace.shared.frontmostApplication?.bundleIdentifier }
                    try #require(away == "com.apple.finder", "Command-Tab must actually leave the game")
                    _ = try await script("tell application \"System Events\" to key code 48 using {command down}")
                    try await Task.sleep(for: .seconds(3))
                    let returned = await MainActor.run { NSWorkspace.shared.frontmostApplication?.processIdentifier }
                    try #require(returned == foregroundPID, "Command-Tab must return to the owned game")
                    try #require(try await script(target + "to get value of attribute \"AXFullScreen\" of " + nativeWindow) == "true")
                    print("E6 native fullscreen survived a real Command-Tab round trip")
                    if quitWithSpace {
                        print("E6 retaining native Space for normal game-quit cleanup verification")
                    } else {
                        _ = try await script(target + "to set value of attribute \"AXFullScreen\" of " + nativeWindow + " to false")
                        try await Task.sleep(for: .seconds(3))
                        if spaceHost {
                            try #require(try await script(target + "to count (windows whose name is \"Gamekit fullscreen Space\")") == "0")
                        } else {
                            try #require(try await script(target + "to get value of attribute \"AXFullScreen\" of " + nativeWindow) == "false")
                        }
                        print("E6 exited native fullscreen successfully")
                    }
                    completedSpaceRoundTrip = true
                }
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
                        if (confirmEnglish || advanceTitle || declineOptionalData || advanceSetupDefaults || (sandboxContinue && foregroundPID.map(guardedPIDs.contains) == true)) && completedScreenActions.count < 9 {
                            let image = destination.appendingPathComponent("sample-\(sample)-\(index).png")
                            let observations = try await recognize(image, crop: sandboxContinue ? "satisfactory" : nil)
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
                            let continueSandbox = sandboxContinue && !completedScreenActions.contains("sandbox load")
                                && Set(["newgame", "load", "options", "exit"]).isSubset(of: words)
                            let sandboxSession = sandboxContinue && completedScreenActions.contains("sandbox load")
                                && !completedScreenActions.contains("sandbox session") && words.contains("deletesession") && words.contains("test")
                            let saveLabel = observations.first { $0.boundingBox.minX > 0.30 && text($0).replacingOccurrences(of: "_", with: "").hasPrefix("testautosave") }.map(text)
                            let sandboxSave = sandboxContinue && completedScreenActions.contains("sandbox session")
                                && !completedScreenActions.contains("sandbox save") && saveLabel != nil
                            let sandboxConfirm = sandboxContinue && completedScreenActions.contains("sandbox save")
                                && !completedScreenActions.contains("sandbox confirm") && words.contains("loadgame") && !words.contains("resumegame")
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
                            let action = sandboxConfirm ? "sandbox confirm" : sandboxSave ? "sandbox save" : sandboxSession ? "sandbox session" : continueSandbox ? "sandbox load" : defaults ?? (optionalData ? "optional data" : (title ? "title" : stage))
                            let label = sandboxConfirm ? "loadgame" : sandboxSave ? (saveLabel ?? "test_autosave_0") : sandboxSession ? "test" : continueSandbox ? "load" : defaults != nil ? "next" : (optionalData ? "decline" : (title ? "pressanybutton" : "confirm"))
                            var buttonBounds = observations.first(where: { text($0) == label })?.boundingBox
                            if defaults != nil {
                                let cropped = try await recognize(image, crop: defaults == "brightness" ? "brightness" : "next-button")
                                if let found = cropped.first(where: { text($0) == "next" })?.boundingBox {
                                    buttonBounds = found
                                }
                            }
                            if sandboxConfirm || sandboxSave || sandboxSession || continueSandbox || language || title || optionalData || defaults != nil, let buttonBounds {
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
            if profileStartup {
                try #require(counters != nil && (countersOnly || cpuProfile != nil), "Profiling must identify the owned game")
                try await cpuProfile?.value
                try await counters?.value
                try await visual?.value
            }
            try #require(!(passiveAfterWarning || tryAgainDriverWarning) || continuedDriverWarning, "Requested warning action must have executed")
            try #require(!spaceRoundTrip || completedSpaceRoundTrip, "Requested Space round trip must execute")
            try #require(!sandboxContinue || completedScreenActions.contains("sandbox load"), "Sandbox Load must have executed")
            try #require(!(expectMoltenVKPairing || expectedMoltenVKLibrary != nil) || verifiedMoltenVKPairing, "Expected paired MoltenVK must be mapped in the owned game")
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
