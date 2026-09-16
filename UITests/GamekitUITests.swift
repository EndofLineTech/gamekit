import GamekitCore
import XCTest

@MainActor
final class GamekitUITests: XCTestCase {
    func testConfirmedCleanResetDeletesOnlyDisposablePrefix() async throws {
        let root = try temporaryRoot()
        let store = try EnvironmentStore(root: root)
        let id = SteamInstallationRecipe.environmentID
        _ = try await store.create(EnvironmentRecord(id: id, name: "Disposable clean reset", runtime: RuntimeProfile.sikarugir.identity,
            installation: .installed, installationRecipeVersion: 1))
        let steam = store.prefixURL(for: id).appendingPathComponent("drive_c/Program Files (x86)/Steam")
        try FileManager.default.createDirectory(at: steam.appendingPathComponent("steamapps"), withIntermediateDirectories: true)
        try Data("fixture".utf8).write(to: steam.appendingPathComponent("Steam.exe"))
        try Data("game".utf8).write(to: steam.appendingPathComponent("steamapps/game.bin"))
        let app = XCUIApplication()
        app.launchArguments = ["--metadata-root", root.path]
        app.launch()
        defer { app.terminate() }
        app.activate()
        XCTAssertTrue(app.staticTexts["Disposable clean reset"].waitForExistence(timeout: 15))
        let reset = app.buttons["reset-delete-downloads"]
        XCTAssertTrue(reset.waitForExistence(timeout: 10))
        revealRecoveryButton(reset, in: app)
        reset.click()
        let confirmation = app.windows["Gamekit"].sheets.firstMatch
        XCTAssertTrue(confirmation.waitForExistence(timeout: 5))
        confirmation.buttons["Delete environment and downloads"].click()
        let status = app.staticTexts["installation-status"]
        let message = "Current environment and its downloads deleted."
        let completed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value BEGINSWITH %@ OR label BEGINSWITH %@", message, message), object: status)
        XCTAssertEqual(XCTWaiter.wait(for: [completed], timeout: 15), .completed, status.debugDescription)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.prefixURL(for: id).path))
        let updated = try await store.load(id)
        XCTAssertEqual(updated?.installation, .notStarted)
    }

    func testOptInNormalQuitAndOrdinaryReopenWhileSteamRuns() async throws {
        guard ProcessInfo.processInfo.environment["GAMEKIT_NORMAL_QUIT_UI_SMOKE"] == "1" else { throw XCTSkip("Opt-in normal quit and Launch Services reopen") }
        let root = try XCTUnwrap(ProcessInfo.processInfo.environment["GAMEKIT_LIFECYCLE_ROOT"])
        let appPath = try XCTUnwrap(ProcessInfo.processInfo.environment["GAMEKIT_APP_PATH"])
        let app = XCUIApplication()
        app.launchArguments = ["--metadata-root", root, "--launch-steam"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Steam: running"].waitForExistence(timeout: 60))
        app.activate()
        app.typeKey("q", modifierFlags: .command)
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 5), "Normal Quit must not wait for Steam shutdown")
        let opened = try await ProcessExecutor().run(.init(executable: URL(fileURLWithPath: "/usr/bin/open"), arguments: [appPath], timeout: 10))
        XCTAssertEqual(opened.termination, .exited(0))
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10), "Ordinary Launch Services reopen must work while Steam remains alive")
        XCTAssertTrue(app.staticTexts["Steam: running"].waitForExistence(timeout: 30))
        app.buttons["stop-steam"].click()
        XCTAssertTrue(app.staticTexts["Steam: stopped"].waitForExistence(timeout: 60))
        app.terminate()
    }

    func testRecoveryResetRequiresConfirmationAndCancellationPreservesMetadata() async throws {
        let root = try temporaryRoot()
        let store = try EnvironmentStore(root: root)
        let record = try EnvironmentRecord(id: SteamInstallationRecipe.environmentID, name: "Recovery fixture",
            runtime: RuntimeProfile.sikarugir.identity, installation: .installed, installationRecipeVersion: 1)
        _ = try await store.create(record)
        let metadata = root.appendingPathComponent("Metadata/Environments/steam.json")
        let original = try Data(contentsOf: metadata)
        let app = XCUIApplication()
        app.launchArguments = ["--metadata-root", root.path]
        app.launch()
        defer { app.terminate() }
        let reset = app.buttons["reset-preserve-downloads"]
        XCTAssertTrue(reset.waitForExistence(timeout: 10))
        for _ in 0..<8 where !reset.isHittable { app.scrollViews.firstMatch.scroll(byDeltaX: 0, deltaY: -500) }
        reset.click()
        let confirmation = app.windows["Gamekit"].sheets.firstMatch
        XCTAssertTrue(confirmation.waitForExistence(timeout: 5))
        XCTAssertTrue(confirmation.buttons["Archive environment and preserve downloads"].exists)
        confirmation.buttons["Cancel"].click()
        XCTAssertEqual(try Data(contentsOf: metadata), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Recovery").path))
        app.buttons["reset-delete-downloads"].click()
        XCTAssertTrue(confirmation.waitForExistence(timeout: 5))
        XCTAssertTrue(confirmation.buttons["Delete environment and downloads"].exists)
        confirmation.buttons["Cancel"].click()
        XCTAssertEqual(try Data(contentsOf: metadata), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Recovery").path))
    }

    func testOptInLiveSteamSurvivesGamekitRestart() async throws {
        guard ProcessInfo.processInfo.environment["GAMEKIT_LIFECYCLE_UI_SMOKE"] == "1" else { throw XCTSkip("Opt-in real Steam lifecycle") }
        let root = try XCTUnwrap(ProcessInfo.processInfo.environment["GAMEKIT_LIFECYCLE_ROOT"])
        let store = try EnvironmentStore(root: URL(fileURLWithPath: root))
        let record = try await store.load(SteamInstallationRecipe.environmentID)
        XCTAssertEqual(record?.installation, .installed)
        guard record?.installation == .installed else { return }
        let logs = try temporaryRoot().deletingLastPathComponent().appendingPathComponent("Logs")
        let app = XCUIApplication()
        app.launchArguments = ["--metadata-root", root, "--diagnostics-root", logs.path, "--launch-steam"]
        app.launch()
        let running = app.staticTexts["Steam: running"]
        XCTAssertTrue(running.waitForExistence(timeout: 60))
        let receiptURL = store.root.appendingPathComponent("Metadata/Lifecycle/steam.json")
        let receiptBeforeQuit = try Data(contentsOf: receiptURL)
        app.terminate()
        // Xcode's UI runner may not inspect another process's kernel arguments.
        // The relaunched app must observe the existing session without a launch flag.
        app.launchArguments = ["--metadata-root", root, "--diagnostics-root", logs.path]
        app.launch()
        XCTAssertTrue(running.waitForExistence(timeout: 30))
        XCTAssertEqual(try Data(contentsOf: receiptURL), receiptBeforeQuit)
        app.buttons["stop-steam"].click()
        XCTAssertTrue(app.staticTexts["Steam: stopped"].waitForExistence(timeout: 60))
        app.terminate()
    }
    func testDiagnosticsAreVisibleAndOfferSummaryExport() async throws {
        let root = try temporaryRoot()
        let logs = root.deletingLastPathComponent().appendingPathComponent("GamekitLogs")
        let store = try DiagnosticStore(base: logs)
        let result = await DiagnosticCommandRunner(store: store).run(
            CommandRequest(executable: URL(fileURLWithPath: "/bin/sh"),
                           arguments: ["-c", "printf PRIVATE_UI_DIAGNOSTIC >&2; exit 23"]), stage: .bootstrap)
        let summary = try XCTUnwrap(result.summary)
        let app = XCUIApplication()
        app.launchArguments = ["--metadata-root", root.path]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["export-diagnostic-\(summary.id.uuidString)"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["local-diagnostic-\(summary.id.uuidString)"].exists)
        let exported = try await store.exportSummary(summary.id)
        XCTAssertFalse(String(decoding: exported, as: UTF8.self).contains("PRIVATE_UI_DIAGNOSTIC"))
    }

    private func temporaryRoot() throws -> URL {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: parent) }
        return parent.appendingPathComponent("Gamekit")
    }

    private func revealRecoveryButton(_ button: XCUIElement, in app: XCUIApplication) {
        let scroll = app.scrollViews.firstMatch
        // A partially clipped button can report hittable while its center is
        // outside the scroll viewport. Avoid clicking during startup layout shifts.
        for _ in 0..<12 {
            if button.isHittable && scroll.frame.insetBy(dx: 0, dy: 16).contains(button.frame) { return }
            scroll.scroll(byDeltaX: 0, deltaY: -160)
        }
        XCTAssertTrue(button.isHittable && scroll.frame.contains(button.frame), button.debugDescription)
    }

    func testNativeAppLaunchesWithLinkedCore() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--metadata-root", try temporaryRoot().path]
        app.launch()
        defer { app.terminate() }

        XCTAssertTrue(app.windows["Gamekit"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["runtime-recipe"].exists)
        XCTAssertTrue(app.staticTexts["host-scope"].exists)
        XCTAssertTrue(app.staticTexts["metadata-empty"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["install-steam"].exists)
        XCTAssertTrue(app.buttons["verify-steam"].exists)
        XCTAssertFalse(app.buttons["confirm-steam-ui"].exists)
    }

    func testSavedMetadataReloadsAfterAppRestartWithoutClaimingRuntimeReadiness() async throws {
        let root = try temporaryRoot()
        let store = try EnvironmentStore(root: root)
        let record = try EnvironmentRecord(id: EnvironmentID("ui-fixture"), name: "UI fixture Steam")
        _ = try await store.create(record)
        let app = XCUIApplication()
        app.launchArguments = ["--metadata-root", root.path]
        defer { app.terminate() }
        for _ in 0..<2 {
            app.launch()
            XCTAssertTrue(app.staticTexts["UI fixture Steam"].waitForExistence(timeout: 10))
            XCTAssertTrue(app.staticTexts["Not checked"].exists)
            app.terminate()
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Environments/ui-fixture").path))
    }

    func testCorruptMetadataShowsErrorAndIsPreserved() throws {
        let root = try temporaryRoot()
        let directory = root.appendingPathComponent("Metadata/Environments")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("broken.json")
        let original = Data("{invalid".utf8)
        try original.write(to: path)
        let app = XCUIApplication()
        app.launchArguments = ["--metadata-root", root.path]
        defer { app.terminate() }
        app.launch()
        XCTAssertTrue(app.staticTexts["metadata-error"].waitForExistence(timeout: 10))
        XCTAssertEqual(try Data(contentsOf: path), original)
    }
}
