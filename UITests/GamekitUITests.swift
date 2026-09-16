import GamekitCore
import XCTest

@MainActor
final class GamekitUITests: XCTestCase {
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
        XCTAssertTrue(app.buttons["Archive environment and preserve downloads"].waitForExistence(timeout: 5))
        app.buttons["Cancel"].click()
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
