@testable import GamekitCore
import XCTest

@MainActor
final class QueuedGameLaunchUITests: XCTestCase {
    func testOnePendingGameLaunchSurvivesNavigationAndSteamAttention() async throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent("Gamekit")
        let store = try EnvironmentStore(root: root)
        let id = SteamInstallationRecipe.environmentID
        _ = try await store.create(.init(id: id, name: "Pending game fixture", runtime: RuntimeProfile.sikarugir.identity,
                                         installation: .installed, installationRecipeVersion: 1))
        let steam = store.prefixURL(for: id).appendingPathComponent(RelativePath.steamDefault.rawValue).deletingLastPathComponent()
        try FileManager.default.createDirectory(at: steam.appendingPathComponent("steamapps/common/Fixture"), withIntermediateDirectories: true)
        try Data("fixture".utf8).write(to: steam.appendingPathComponent("Steam.exe"))
        try Data(#""AppState" { "appid" "42" "name" "Fixture" "installdir" "Fixture" "StateFlags" "4" }"#.utf8)
            .write(to: steam.appendingPathComponent("steamapps/appmanifest_42.acf"))
        let logs = root.appendingPathComponent("UIFixtureLaunch")
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let log = logs.appendingPathComponent("console_log.txt")
        try Data("[2026-09-27 00:00:00] Game process added : AppID 42 old\n".utf8).write(to: log)

        let app = XCUIApplication()
        app.launchArguments = ["--metadata-root", root.path, "--ui-test-scenario", "queued-game-launch"]
        app.launch(); defer { app.terminate() }
        let tile = app.buttons["select-game-42"]
        XCTAssertTrue(tile.waitForExistence(timeout: 20))
        tile.click()
        let play = app.buttons["launch-game-42"]
        XCTAssertTrue(play.waitForExistence(timeout: 10))
        let canPlay = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: play)
        XCTAssertEqual(XCTWaiter.wait(for: [canPlay], timeout: 20), .completed)
        play.click()
        let status = app.staticTexts["persistent-game-status"]
        let pending = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value CONTAINS %@", "Waiting for Steam to acknowledge"), object: status)
        XCTAssertEqual(XCTWaiter.wait(for: [pending], timeout: 15), .completed)
        XCTAssertFalse(play.isEnabled, "A pending observation cannot send Play again")

        app.buttons["library-view-list"].click()
        XCTAssertTrue(app.outlines["library-game-table"].waitForExistence(timeout: 10))
        app.buttons["library-view-grid"].click()
        app.buttons["nav-diagnostics"].click()
        XCTAssertTrue(app.staticTexts["diagnostics-heading"].waitForExistence(timeout: 10))
        XCTAssertTrue(status.exists, "The window retains game status without its inspector")
        app.buttons["nav-settings"].click()
        XCTAssertTrue(app.buttons["settings-Launchers"].waitForExistence(timeout: 10))
        app.buttons["settings-Launchers"].click()
        app.buttons["back-to-library"].click()
        XCTAssertTrue(tile.waitForExistence(timeout: 10))
        XCTAssertFalse(play.isEnabled, "Navigation must not reset the pending game gate")

        let handle = try FileHandle(forWritingTo: log)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("[2026-09-27 00:00:01] GameAction [AppID 42, ActionID 1] : LaunchApp waiting for user response to SynchronizingCloud fixture\n".utf8))
        try handle.close()
        let attention = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value CONTAINS %@", "Steam Cloud needs your attention"), object: status)
        XCTAssertEqual(XCTWaiter.wait(for: [attention], timeout: 10), .completed)
        XCTAssertFalse(play.isEnabled, "Gamekit leaves the Cloud decision to the user")

        let finished = try FileHandle(forWritingTo: log)
        try finished.seekToEnd()
        try finished.write(contentsOf: Data("[2026-09-27 00:00:02] Game process added : AppID 42 fixture\n".utf8))
        try finished.close()
        let created = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value CONTAINS %@", "Steam created a game process"), object: status)
        XCTAssertEqual(XCTWaiter.wait(for: [created], timeout: 10), .completed)
        let summaries = try await DiagnosticStore(base: parent.appendingPathComponent("GamekitLogs")).summaries()
        XCTAssertEqual(summaries.filter { $0.stage == .launch && $0.component == .steam }.count, 1,
                       "Selection, navigation and Cloud attention cannot generate another request")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Metadata/Lifecycle/steam.json").path),
                       "The isolated observation never launches a real managed Steam session")
    }
}
