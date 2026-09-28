@testable import GamekitCore
import XCTest

@MainActor
final class LibraryStressUITests: XCTestCase {
    func testSyntheticLibraryStaysBrowsableWhenOneReceiptBecomesUnreadable() async throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent("Gamekit")
        let store = try EnvironmentStore(root: root)
        let id = SteamInstallationRecipe.environmentID
        _ = try await store.create(.init(id: id, name: "Stress fixture", runtime: RuntimeProfile.sikarugir.identity,
                                         installation: .installed, installationRecipeVersion: 1))
        let steam = store.prefixURL(for: id).appendingPathComponent(RelativePath.steamDefault.rawValue).deletingLastPathComponent()
        let apps = steam.appendingPathComponent("steamapps")
        try FileManager.default.createDirectory(at: apps.appendingPathComponent("common"), withIntermediateDirectories: true)
        try Data("fixture".utf8).write(to: steam.appendingPathComponent("Steam.exe"))
        for index in 0..<128 {
            let appID = 100_000 + index
            let title = index.isMultiple(of: 13) ? "Duplicate title" : "Fixture \(index)"
            let folder = "entry-\(index)"
            if !index.isMultiple(of: 11) {
                try FileManager.default.createDirectory(at: apps.appendingPathComponent("common/\(folder)"), withIntermediateDirectories: true)
            }
            let flags = index.isMultiple(of: 7) ? "1026" : "4"
            let size = index.isMultiple(of: 5) ? "" : String(index * 1024)
            let receipt = #""AppState" { "appid" "\#(appID)" "name" "\#(title)" "installdir" "\#(folder)" "StateFlags" "\#(flags)" "SizeOnDisk" "\#(size)" }"#
            try Data(receipt.utf8).write(to: apps.appendingPathComponent("appmanifest_\(appID).acf"))
        }
        let clock = ContinuousClock()
        let started = clock.now
        let app = XCUIApplication()
        app.launchArguments = ["--metadata-root", root.path, "--ui-test-scenario", "invalid-runtime"]
        app.launch(); defer { app.terminate() }
        let selected = app.buttons["select-game-100000"]
        XCTAssertTrue(selected.waitForExistence(timeout: 20))
        selected.click()
        XCTAssertTrue(app.buttons["launch-game-100000"].waitForExistence(timeout: 10))
        let selectedAt = clock.now

        app.buttons["library-view-list"].click()
        let sort = app.popUpButtons["library-sort"]
        sort.click(); app.menuItems["Reported size"].click()
        let table = app.outlines["library-game-table"]
        XCTAssertTrue(table.waitForExistence(timeout: 10))
        let firstRow = table.descendants(matching: .outlineRow).element(boundBy: 0)
        XCTAssertTrue(firstRow.buttons["select-game-100127"].waitForExistence(timeout: 10))
        let sortedAt = clock.now

        let search = app.textFields["library-search"]
        search.click(); search.typeText("Fixture 12")
        XCTAssertTrue(app.staticTexts["9 installations · Windows Steam"].waitForExistence(timeout: 10))
        let searchedAt = clock.now
        search.typeKey("a", modifierFlags: .command); search.typeKey(.delete, modifierFlags: [])

        try Data("incomplete".utf8).write(to: apps.appendingPathComponent("appmanifest_100000.acf"))
        // A full 128-receipt refresh and SwiftUI table update can overlap on CI.
        XCTAssertTrue(app.staticTexts["1 Steam installation record could not be read. Let Steam finish its changes, then refresh."].waitForExistence(timeout: 30))
        XCTAssertTrue(app.staticTexts["128 installations · Windows Steam"].exists,
                      "An unreadable manifest must not discard the last known installation or fabricate an empty library")
        XCTAssertTrue(app.buttons["launch-game-100000"].exists, "Selection survives the partial scan")
        XCTAssertFalse(app.buttons["launch-game-100000"].isEnabled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Metadata/Lifecycle/steam.json").path))
        print("Synthetic 128-title native library: first selection=\(started.duration(to: selectedAt)), list sort=\(selectedAt.duration(to: sortedAt)), search=\(sortedAt.duration(to: searchedAt))")
    }
}
