@testable import GamekitCore
import XCTest

@MainActor
final class LibraryCoverSizingUITests: XCTestCase {
    func testWindowResizeKeepsSavedCoverWidth() async throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent("Gamekit")
        _ = try await LibraryPreferencesStore(root: root).setCoverSize(180)
        let store = try EnvironmentStore(root: root)
        let id = SteamInstallationRecipe.environmentID
        _ = try await store.create(.init(id: id, name: "Cover sizing fixture", runtime: RuntimeProfile.sikarugir.identity,
                                         installation: .installed, installationRecipeVersion: 1))
        let steam = store.prefixURL(for: id).appendingPathComponent(RelativePath.steamDefault.rawValue).deletingLastPathComponent()
        try FileManager.default.createDirectory(at: steam.appendingPathComponent("steamapps/common/Fixture"), withIntermediateDirectories: true)
        try Data("fixture".utf8).write(to: steam.appendingPathComponent("Steam.exe"))
        try Data(#""AppState" { "appid" "42" "name" "Fixture" "installdir" "Fixture" "StateFlags" "4" }"#.utf8)
            .write(to: steam.appendingPathComponent("steamapps/appmanifest_42.acf"))

        let app = XCUIApplication()
        app.launchArguments = ["--metadata-root", root.path, "--ui-test-scenario", "invalid-runtime"]
        app.launch(); defer { app.terminate() }
        let tile = app.buttons["select-game-42"]
        XCTAssertTrue(tile.waitForExistence(timeout: 20))
        for _ in 0..<20 {
            if abs(tile.frame.width - 180) <= 3 { break }
            try await Task.sleep(for: .milliseconds(200))
        }
        XCTAssertEqual(tile.frame.width, 180, accuracy: 3, "Saved cover size sets the artwork width")

        let window = app.windows["Gamekit"]
        let initialWidth = window.frame.width
        let corner = window.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 1))
            .withOffset(CGVector(dx: -4, dy: -4))
        corner.press(forDuration: 0.2, thenDragTo: corner.withOffset(CGVector(dx: -105, dy: -40)))
        for _ in 0..<20 {
            if window.frame.width < initialWidth - 30 { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertLessThan(window.frame.width, initialWidth - 30, "The window must actually resize")
        XCTAssertEqual(tile.frame.width, 180, accuracy: 3, "Window width must not scale a game's cover")
        let savedCoverSize = try await LibraryPreferencesStore(root: root).load().coverSize
        XCTAssertEqual(savedCoverSize, 180)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Metadata/Lifecycle/steam.json").path))
    }
}
