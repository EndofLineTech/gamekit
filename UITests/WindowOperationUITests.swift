import XCTest

@MainActor
final class WindowOperationUITests: XCTestCase {
    func testPrerequisiteOperationFinishesAcrossLibrarySettingsAndDiagnostics() async throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent("Gamekit")
        let app = XCUIApplication()
        app.launchArguments = ["--metadata-root", root.path, "--ui-test-scenario", "ready-with-delay"]
        app.launch(); defer { app.terminate() }
        XCTAssertTrue(app.staticTexts["library-heading"].waitForExistence(timeout: 15))
        app.buttons["nav-settings"].click()
        let launchers = app.buttons["settings-Launchers"]
        XCTAssertTrue(launchers.waitForExistence(timeout: 10))
        launchers.click()
        XCTAssertTrue(app.staticTexts["Ready to install and launch"].waitForExistence(timeout: 15))
        app.typeKey("r", modifierFlags: [.command, .shift])
        let activity = app.staticTexts["operation-status"]
        XCTAssertTrue(activity.waitForExistence(timeout: 5))
        XCTAssertTrue((activity.value as? String ?? "").contains("Checking prerequisites"))
        app.buttons["back-to-library"].click()
        XCTAssertTrue(activity.exists, "Leaving Settings must not cancel the pending operation")
        app.buttons["nav-diagnostics"].click()
        XCTAssertTrue(app.staticTexts["diagnostics-heading"].waitForExistence(timeout: 10))
        XCTAssertTrue(activity.exists, "Leaving setup must not cancel or hide the window's pending operation")
        app.activate()
        app.buttons["nav-settings"].click()
        XCTAssertTrue(launchers.waitForExistence(timeout: 10))
        launchers.click()
        XCTAssertTrue(app.staticTexts["Ready to install and launch"].waitForExistence(timeout: 15),
                      "The original operation must complete after navigation")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Metadata/Lifecycle/steam.json").path),
                       "Navigating never dispatches a managed Steam launch")
    }
}
