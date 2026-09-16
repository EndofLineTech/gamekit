import GamekitCore
import XCTest

@MainActor
final class GamekitUITests: XCTestCase {
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
