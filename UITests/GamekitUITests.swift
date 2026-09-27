@testable import GamekitCore
import XCTest

@MainActor
final class GamekitUITests: XCTestCase {
    func testInspectorSummarizesSavedChoicesAndGatesManagedGameFiles() async throws {
        let root = try temporaryRoot()
        let store = try EnvironmentStore(root: root)
        let id = SteamInstallationRecipe.environmentID
        _ = try await store.create(.init(id: id, name: "Inspector fixture", runtime: RuntimeProfile.sikarugir.identity,
                                         installation: .installed, installationRecipeVersion: 1))
        let steam = store.prefixURL(for: id).appendingPathComponent(RelativePath.steamDefault.rawValue).deletingLastPathComponent()
        try FileManager.default.createDirectory(at: steam.appendingPathComponent("steamapps/common/Fixture"), withIntermediateDirectories: true)
        try Data("fixture".utf8).write(to: steam.appendingPathComponent("Steam.exe"))
        let manifest = steam.appendingPathComponent("steamapps/appmanifest_42.acf")
        func writeManifest(flags: Int) throws {
            try Data(#""AppState" { "appid" "42" "name" "Fixture" "installdir" "Fixture" "StateFlags" "\#(flags)" }"#.utf8)
                .write(to: manifest)
        }
        try writeManifest(flags: 4)
        let app = XCUIApplication()
        app.launchArguments = ["--metadata-root", root.path, "--ui-test-scenario", "invalid-runtime"]
        app.launch(); defer { app.terminate() }
        openGameInspector(42, in: app)
        XCTAssertTrue(app.staticTexts["inspector-graphics-42"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["inspector-space-42"].exists)
        let files = app.buttons["game-files-42"]
        XCTAssertTrue(files.exists && files.isEnabled, "Revealing a ready folder does not require launching Wine")
        try writeManifest(flags: 1026)
        let disabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == false"), object: files)
        XCTAssertEqual(XCTWaiter.wait(for: [disabled], timeout: 15), .completed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Metadata/Lifecycle/steam.json").path))
    }

    func testNativeTableSortsKnownZeroAndUnknownSizesWithoutLosingSelection() async throws {
        let root = try temporaryRoot()
        let store = try EnvironmentStore(root: root)
        let id = SteamInstallationRecipe.environmentID
        _ = try await store.create(.init(id: id, name: "Table fixture", runtime: RuntimeProfile.sikarugir.identity,
                                         installation: .installed, installationRecipeVersion: 1))
        let steam = store.prefixURL(for: id).appendingPathComponent(RelativePath.steamDefault.rawValue).deletingLastPathComponent()
        try FileManager.default.createDirectory(at: steam, withIntermediateDirectories: true)
        try Data("fixture".utf8).write(to: steam.appendingPathComponent("Steam.exe"))
        for (appID, title, size, filesPresent) in [(42, "Alpha", nil, true), (43, "Beta", "0", true),
                                                    (44, "Charlie", "500000", true), (45, "Delta", nil, false)] {
            if filesPresent {
                try FileManager.default.createDirectory(at: steam.appendingPathComponent("steamapps/common/\(title)"), withIntermediateDirectories: true)
            }
            let receipt = #""AppState" { "appid" "\#(appID)" "name" "\#(title)" "installdir" "\#(title)" "StateFlags" "4" "SizeOnDisk" "\#(size ?? "")" }"#
            try Data(receipt.utf8).write(to: steam.appendingPathComponent("steamapps/appmanifest_\(appID).acf"))
        }
        let app = XCUIApplication()
        app.launchArguments = ["--metadata-root", root.path, "--ui-test-scenario", "invalid-runtime"]
        app.launch(); defer { app.terminate() }
        XCTAssertTrue(app.buttons["select-game-42"].waitForExistence(timeout: 20))
        app.buttons["library-view-list"].click()
        let table = app.outlines["library-game-table"]
        XCTAssertTrue(table.waitForExistence(timeout: 10))
        let rows = table.descendants(matching: .outlineRow)
        XCTAssertTrue(rows.element(boundBy: 0).buttons["select-game-42"].exists)
        app.buttons["select-game-43"].click()
        XCTAssertTrue(app.buttons["launch-game-43"].waitForExistence(timeout: 10))
        app.typeKey(.downArrow, modifierFlags: [])
        XCTAssertTrue(app.buttons["launch-game-44"].waitForExistence(timeout: 10), "The native table moves selection by row")
        app.typeKey(.upArrow, modifierFlags: [])
        XCTAssertTrue(app.buttons["launch-game-43"].waitForExistence(timeout: 10))
        app.buttons["toggle-inspector"].click()
        let lastHeader = table.buttons["Reported size"]
        XCTAssertTrue(lastHeader.exists)
        XCTAssertLessThanOrEqual(lastHeader.frame.maxX, table.frame.maxX, "All columns fit at compact width")
        let sort = app.popUpButtons["library-sort"]
        sort.click(); app.menuItems["Reported size"].click()
        let compactList = XCTAttachment(screenshot: app.screenshot())
        compactList.name = "native-library-table-compact"
        compactList.lifetime = .keepAlways
        add(compactList)
        XCTAssertTrue(rows.element(boundBy: 0).buttons["select-game-44"].waitForExistence(timeout: 10))
        XCTAssertTrue(rows.element(boundBy: 1).buttons["select-game-43"].exists, "A reported zero sorts ahead of unknown sizes")
        app.buttons["library-view-grid"].click()
        app.buttons["library-view-list"].click()
        XCTAssertTrue(rows.element(boundBy: 0).buttons["select-game-44"].waitForExistence(timeout: 10))
        app.buttons["toggle-inspector"].click()
        XCTAssertTrue(app.buttons["launch-game-43"].waitForExistence(timeout: 10), "Both views retain the same selected installation")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Metadata/Lifecycle/steam.json").path))
    }

    func testGridKeyboardFocusMovesWithoutLaunchingAndReturnSelects() async throws {
        let root = try temporaryRoot()
        let store = try EnvironmentStore(root: root)
        let id = SteamInstallationRecipe.environmentID
        _ = try await store.create(.init(id: id, name: "Keyboard fixture", runtime: RuntimeProfile.sikarugir.identity,
                                         installation: .installed, installationRecipeVersion: 1))
        let steam = store.prefixURL(for: id).appendingPathComponent(RelativePath.steamDefault.rawValue).deletingLastPathComponent()
        try FileManager.default.createDirectory(at: steam, withIntermediateDirectories: true)
        try Data("fixture".utf8).write(to: steam.appendingPathComponent("Steam.exe"))
        for (appID, title) in [(42, "Alpha"), (43, "Beta"), (44, "Charlie"), (45, "Delta")] {
            try FileManager.default.createDirectory(at: steam.appendingPathComponent("steamapps/common/\(title)"), withIntermediateDirectories: true)
            let manifest = #""AppState" { "appid" "\#(appID)" "name" "\#(title)" "installdir" "\#(title)" "StateFlags" "4" }"#
            try Data(manifest.utf8).write(to: steam.appendingPathComponent("steamapps/appmanifest_\(appID).acf"))
        }
        let app = XCUIApplication()
        app.launchArguments = ["--metadata-root", root.path, "--ui-test-scenario", "invalid-runtime"]
        app.launch(); defer { app.terminate() }
        let first = app.buttons["select-game-42"]
        XCTAssertTrue(first.waitForExistence(timeout: 20))
        first.click()
        XCTAssertTrue(app.buttons["launch-game-42"].waitForExistence(timeout: 10))
        app.typeKey(.rightArrow, modifierFlags: [])
        XCTAssertTrue(app.buttons["launch-game-42"].exists, "Arrow keys move focus without selecting or playing")
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(app.buttons["launch-game-43"].waitForExistence(timeout: 10))
        app.typeKey(.home, modifierFlags: [])
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(app.buttons["launch-game-42"].waitForExistence(timeout: 10))
        app.typeKey(.downArrow, modifierFlags: [])
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(app.buttons["launch-game-45"].waitForExistence(timeout: 10), "Down moves by the displayed column count")
        app.typeKey(.end, modifierFlags: [])
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(app.buttons["launch-game-45"].waitForExistence(timeout: 10))
        app.typeKey(.leftArrow, modifierFlags: [])
        app.typeKey(.space, modifierFlags: [])
        XCTAssertTrue(app.buttons["launch-game-44"].waitForExistence(timeout: 10), "Space selects without playing")
        app.typeKey(.upArrow, modifierFlags: [])
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(app.buttons["launch-game-42"].waitForExistence(timeout: 10))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Metadata/Lifecycle/steam.json").path))
    }

    func testNativeLibraryShellNavigationNeverLaunchesOnSelection() async throws {
        let root = try temporaryRoot()
        let store = try EnvironmentStore(root: root)
        let id = SteamInstallationRecipe.environmentID
        _ = try await store.create(.init(id: id, name: "Library fixture", runtime: RuntimeProfile.sikarugir.identity,
                                         installation: .installed, installationRecipeVersion: 1))
        let steam = store.prefixURL(for: id).appendingPathComponent(RelativePath.steamDefault.rawValue).deletingLastPathComponent()
        try FileManager.default.createDirectory(at: steam.appendingPathComponent("steamapps/common/Fixture"), withIntermediateDirectories: true)
        try Data("fixture".utf8).write(to: steam.appendingPathComponent("Steam.exe"))
        try Data(#""AppState" { "appid" "42" "name" "Fixture" "installdir" "Fixture" "StateFlags" "4" }"#.utf8)
            .write(to: steam.appendingPathComponent("steamapps/appmanifest_42.acf"))
        let app = XCUIApplication()
        app.launchArguments = ["--metadata-root", root.path, "--ui-test-scenario", "invalid-runtime"]
        app.launch(); defer { app.terminate() }
        XCTAssertTrue(app.staticTexts["library-heading"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["nav-ubisoft"].exists)
        let item = app.buttons["select-game-42"]
        XCTAssertTrue(item.waitForExistence(timeout: 20))
        item.click()
        XCTAssertTrue(app.buttons["launch-game-42"].waitForExistence(timeout: 10))
        let gridCapture = XCTAttachment(screenshot: app.screenshot())
        gridCapture.name = "native-library-grid"
        gridCapture.lifetime = .keepAlways
        add(gridCapture)
        XCTAssertFalse(app.buttons["launch-game-42"].isEnabled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Metadata/Lifecycle/steam.json").path))
        app.buttons["nav-diagnostics"].click()
        XCTAssertTrue(app.staticTexts["diagnostics-heading"].waitForExistence(timeout: 10))
        app.buttons["nav-settings"].click()
        XCTAssertTrue(app.buttons["settings-General"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["settings-Game defaults"].exists)
        XCTAssertTrue(app.buttons["settings-Runtime"].exists)
        XCTAssertTrue(app.buttons["settings-Storage"].exists)
        app.buttons["back-to-launchers"].click()
        XCTAssertTrue(app.staticTexts["launchers-heading"].waitForExistence(timeout: 10))
        app.buttons["library-all"].click()
        XCTAssertTrue(item.waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["launch-game-42"].exists, "Selection must survive navigation")
        app.buttons["favorite-game-42"].click()
        let preferences = LibraryPreferencesStore(root: root)
        let favoriteID = SteamGameInstallationID(environmentID: id, appID: 42)
        for _ in 0..<40 {
            if (try? await preferences.load().favorites.contains(favoriteID)) == true { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        let savedFavorites = try await preferences.load().favorites
        XCTAssertTrue(savedFavorites.contains(favoriteID))
        app.buttons["library-favorites"].click()
        XCTAssertTrue(item.waitForExistence(timeout: 10))
        app.buttons["library-all"].click()
        let listMode = app.buttons["library-view-list"]
        XCTAssertTrue(listMode.waitForExistence(timeout: 10))
        listMode.click()
        XCTAssertTrue(item.waitForExistence(timeout: 10))
        let listCapture = XCTAttachment(screenshot: app.screenshot())
        listCapture.name = "native-library-list"
        listCapture.lifetime = .keepAlways
        add(listCapture)
        let savedMode = try await preferences.load().viewMode
        XCTAssertEqual(savedMode, .list)
        XCTAssertTrue(app.buttons["launch-game-42"].exists, "Grid and list share the inspector selection")
        let search = app.textFields["library-search"]
        search.click(); search.typeText("no match")
        XCTAssertTrue(app.staticTexts["No matching games"].waitForExistence(timeout: 10))
        app.buttons["Clear filters"].click()
        XCTAssertTrue(item.waitForExistence(timeout: 10))
        app.typeKey(",", modifierFlags: .command)
        XCTAssertTrue(app.buttons["back-to-launchers"].waitForExistence(timeout: 10))
        app.buttons["back-to-launchers"].click()
        app.buttons["library-all"].click()
        XCTAssertTrue(item.waitForExistence(timeout: 10))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Metadata/Lifecycle/steam.json").path))
    }

    func testInstalledAlternativeBackendsAreSelectableAndIndependent() async throws {
        guard let primary = ProcessInfo.processInfo.environment["GAMEKIT_UI_PRIMARY_ROOT"] else {
            throw XCTSkip("Set TEST_RUNNER_GAMEKIT_UI_PRIMARY_ROOT for local pinned-payload acceptance")
        }
        let selected = try await RuntimeSettingsStore(store: EnvironmentStore(root: URL(fileURLWithPath: primary))).layout()
        try XCTSkipUnless(selected.isGraphicsBackendAvailable(.dxmt) && selected.isGraphicsBackendAvailable(.dxvk), "Local pinned payload acceptance")
        let root = try temporaryRoot()
        let store = try EnvironmentStore(root: root)
        let id = SteamInstallationRecipe.environmentID
        try await RuntimeSettingsStore(store: store).select(selected.bundle, revision: selected.profile.revision, graphicsBackend: .metal3)
        _ = try await store.create(.init(id: id, name: "Backend UI fixture", runtime: RuntimeProfile.sikarugir.identity, installation: .installed, installationRecipeVersion: 1))
        let payloads = root.appendingPathComponent("GraphicsBackends")
        try FileManager.default.createDirectory(at: payloads, withIntermediateDirectories: true)
        for revision in ["dxmt-0.80-compat2", "dxvk-macos-1.10.3-compat2"] {
            try FileManager.default.copyItem(at: selected.dataRoot.appendingPathComponent("GraphicsBackends/" + revision), to: payloads.appendingPathComponent(revision))
        }
        let steam = store.prefixURL(for: id).appendingPathComponent("drive_c/Program Files (x86)/Steam")
        try FileManager.default.createDirectory(at: steam.appendingPathComponent("steamapps/common/Fixture"), withIntermediateDirectories: true)
        try Data("fixture".utf8).write(to: steam.appendingPathComponent("Steam.exe"))
        try Data(#""AppState" { "appid" "123456" "name" "Fixture" "installdir" "Fixture" "StateFlags" "4" }"#.utf8).write(to: steam.appendingPathComponent("steamapps/appmanifest_123456.acf"))
        let app = XCUIApplication()
        app.launchArguments = ["--metadata-root", root.path, "--ui-test-scenario", "ready"]
        app.launch(); defer { app.terminate() }
        openLaunchers(in: app)
        let shared = app.popUpButtons["graphics-backend-picker"]
        XCTAssertTrue(shared.waitForExistence(timeout: 30))
        revealRecoveryButton(shared, in: app)
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: shared)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 30), .completed)
        shared.click()
        XCTAssertTrue(app.menuItems["DXVK (Direct3D 10/11)"].isEnabled)
        XCTAssertTrue(app.menuItems["DXMT (Direct3D 10/11)"].isEnabled)
        app.menuItems["DXVK (Direct3D 10/11)"].click()
        let saved = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value CONTAINS 'DXVK'"), object: app.staticTexts["selected-graphics-backend"])
        XCTAssertEqual(XCTWaiter.wait(for: [saved], timeout: 30), .completed)
        app.buttons["library-all"].click()
        openGameInspector(123456, in: app)
        let gear = app.buttons["game-compatibility-123456"]
        revealRecoveryButton(gear, in: app); gear.click()
        let gamePicker = app.popUpButtons["game-graphics-backend-picker"]
        XCTAssertTrue(gamePicker.waitForExistence(timeout: 20))
        let gameReady = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: gamePicker)
        XCTAssertEqual(XCTWaiter.wait(for: [gameReady], timeout: 20), .completed)
        gamePicker.click(); app.menuItems["DXMT (Direct3D 10/11)"].click()
        let effective = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value CONTAINS 'DXMT'"), object: app.staticTexts["game-effective-backend"])
        XCTAssertEqual(XCTWaiter.wait(for: [effective], timeout: 20), .completed)
        app.terminate(); app.launch()
        openGameInspector(123456, in: app)
        XCTAssertTrue(gear.waitForExistence(timeout: 30)); revealRecoveryButton(gear, in: app); gear.click()
        XCTAssertTrue(gamePicker.waitForExistence(timeout: 20))
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "value CONTAINS 'DXMT'"), object: app.staticTexts["game-effective-backend"])], timeout: 20), .completed)
        let snapshot = try await GameCompatibilityStore(store: store).inspectGraphics(appID: 123456)
        XCTAssertEqual(snapshot.override, .dxmt)
        XCTAssertEqual(snapshot.sharedBackend, .dxvk)
    }
    func testPerGameBackendPersistsWithoutChangingSharedDefault() async throws {
        let root = try temporaryRoot()
        let store = try EnvironmentStore(root: root)
        let id = SteamInstallationRecipe.environmentID
        _ = try await store.create(.init(id: id, name: "Graphics fixture", runtime: RuntimeProfile.sikarugir.identity, installation: .installed, installationRecipeVersion: 1))
        let steam = store.prefixURL(for: id).appendingPathComponent("drive_c/Program Files (x86)/Steam")
        try FileManager.default.createDirectory(at: steam.appendingPathComponent("steamapps/common/Fixture Game"), withIntermediateDirectories: true)
        try Data("fixture".utf8).write(to: steam.appendingPathComponent("Steam.exe"))
        try Data(#""AppState" { "appid" "123456" "name" "Fixture Game" "installdir" "Fixture Game" "StateFlags" "4" }"#.utf8).write(to: steam.appendingPathComponent("steamapps/appmanifest_123456.acf"))
        let app = XCUIApplication()
        app.launchArguments = ["--metadata-root", root.path, "--ui-test-scenario", "ready"]
        app.launch(); defer { app.terminate() }
        func openPanel() {
            openGameInspector(123456, in: app)
            let gear = app.buttons["game-compatibility-123456"]
            XCTAssertTrue(gear.waitForExistence(timeout: 20)); revealRecoveryButton(gear, in: app); gear.click()
            XCTAssertTrue(app.popUpButtons["game-graphics-backend-picker"].waitForExistence(timeout: 15))
            XCTAssertTrue(app.popUpButtons["game-fullscreen-space-picker"].exists, "Games without a specific profile still offer the Space override")
        }
        func choose(_ title: String, effective: String) {
            let picker = app.popUpButtons["game-graphics-backend-picker"]
            let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: picker)
            XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 15), .completed)
            picker.click()
            XCTAssertFalse(app.menuItems["DXVK (Direct3D 10/11) — Not installed"].isEnabled)
            XCTAssertFalse(app.menuItems["DXMT (Direct3D 10/11) — Not installed"].isEnabled)
            app.menuItems[title].click()
            let value = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value CONTAINS %@", effective), object: app.staticTexts["game-effective-backend"])
            XCTAssertEqual(XCTWaiter.wait(for: [value], timeout: 15), .completed)
        }
        openPanel(); choose("Metal 3 compatibility", effective: "Metal 3")
        let shared = try await RuntimeSettingsStore(store: store).layout()
        XCTAssertEqual(shared.graphicsBackend, .automatic)
        app.terminate(); app.launch(); openPanel()
        XCTAssertTrue((app.staticTexts["game-effective-backend"].value as? String ?? "").contains("Metal 3"))
        choose("Use shared default", effective: "Automatic")
        let snapshot = try await GameCompatibilityStore(store: store).inspectGraphics(appID: 123456)
        XCTAssertEqual(snapshot.override, .inherit)
    }
    func testSharedFullscreenSpaceCanBeChangedAndReopened() async throws {
        let root = try temporaryRoot()
        let store = try EnvironmentStore(root: root)
        let app = XCUIApplication()
        app.launchArguments = ["--metadata-root", root.path, "--ui-test-scenario", "ready"]
        app.launch(); defer { app.terminate() }
        openLaunchers(in: app)
        let toggle = app.checkBoxes["shared-fullscreen-space"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 20))
        revealRecoveryButton(toggle, in: app)
        XCTAssertEqual(toggle.value as? Int, 0)
        toggle.click()
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == 1"), object: toggle)
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 15), .completed)
        let stored = try await RuntimeSettingsStore(store: store).sharedFullscreenSpace()
        XCTAssertTrue(stored)
        app.terminate(); app.launch(); openLaunchers(in: app)
        XCTAssertTrue(toggle.waitForExistence(timeout: 20))
        XCTAssertEqual(toggle.value as? Int, 1)
    }
    func testDebugCaptureIsOptInAndResetsWhenAppReopens() throws {
        let root = try temporaryRoot()
        let app = XCUIApplication()
        app.launchArguments = ["--metadata-root", root.path, "--ui-test-scenario", "ready"]
        app.launch()
        defer { app.terminate() }
        app.buttons["nav-diagnostics"].click()
        let toggle = app.checkBoxes["debug-performance-mode"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 20))
        revealRecoveryButton(toggle, in: app)
        XCTAssertEqual(toggle.value as? Int, 0)
        toggle.click()
        XCTAssertEqual(toggle.value as? Int, 1)
        XCTAssertFalse(app.buttons["stop-debug-capture"].isEnabled)
        app.terminate(); app.launch(); app.buttons["nav-diagnostics"].click()
        XCTAssertTrue(toggle.waitForExistence(timeout: 20))
        XCTAssertEqual(toggle.value as? Int, 0)
    }
    func testPerGameCaptureSettingsPersistAndRestoreDefaults() async throws {
        let root = try temporaryRoot()
        let store = try EnvironmentStore(root: root)
        let id = SteamInstallationRecipe.environmentID
        _ = try await store.create(.init(id: id, name: "Compatibility fixture", runtime: RuntimeProfile.sikarugir.identity, installation: .installed, installationRecipeVersion: 1))
        let prefix = store.prefixURL(for: id)
        let steam = prefix.appendingPathComponent("drive_c/Program Files (x86)/Steam")
        try FileManager.default.createDirectory(at: steam.appendingPathComponent("steamapps/common/Fixture"), withIntermediateDirectories: true)
        try Data("fixture".utf8).write(to: steam.appendingPathComponent("Steam.exe"))
        try Data(#""AppState" { "appid" "42" "name" "Fixture" "installdir" "Fixture" "StateFlags" "4" }"#.utf8).write(to: steam.appendingPathComponent("steamapps/appmanifest_42.acf"))
        try Data("WINE REGISTRY Version 2\n#arch=win64\n".utf8).write(to: prefix.appendingPathComponent("user.reg"))
        var profile = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(GameProfileStore.bundled(appID: GameFixtures.primary.appId))) as? [String: Any])
        profile["appId"] = 42; profile["revision"] = 99; profile["name"] = "Fixture"
        var execution = try XCTUnwrap(profile["execution"] as? [String: Any])
        execution["executable"] = "custom.exe"
        var capture = try XCTUnwrap(execution["capture"] as? [String: Any])
        capture["guidance"] = "Capture guidance from the downloaded JSON fixture."
        execution["capture"] = capture; profile["execution"] = execution
        let profiles = root.appendingPathComponent("Metadata/GameProfiles")
        try FileManager.default.createDirectory(at: profiles, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: profile).write(to: profiles.appendingPathComponent("42.json"))
        let app = XCUIApplication()
        app.launchArguments = ["--metadata-root", root.path, "--ui-test-scenario", "ready"]
        app.launch()
        defer { app.terminate() }
        func openSettings() {
            openGameInspector(42, in: app)
            let open = app.buttons["game-compatibility-42"]
            XCTAssertTrue(open.waitForExistence(timeout: 20))
            revealRecoveryButton(open, in: app); open.click()
            XCTAssertTrue(app.staticTexts["game-capture-setting"].waitForExistence(timeout: 15))
        }
        func change(_ button: String, expected: String) {
            let control = app.buttons[button]
            let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: control)
            XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 15), .completed)
            control.click()
            let value = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value BEGINSWITH %@", expected), object: app.staticTexts["game-capture-setting"])
            XCTAssertEqual(XCTWaiter.wait(for: [value], timeout: 15), .completed)
        }
        openSettings()
        XCTAssertTrue(app.staticTexts["Capture guidance from the downloaded JSON fixture."].exists)
        XCTAssertTrue(app.sheets.firstMatch.popUpButtons["game-graphics-backend-picker"].exists)
        change("enable-game-capture", expected: "Enabled for this game")
        change("disable-game-capture", expected: "Disabled for this game")
        change("restore-game-defaults", expected: "Inherit Wine default")
        change("enable-game-capture", expected: "Enabled for this game")
        app.terminate(); app.launch()
        openSettings()
        XCTAssertTrue((app.staticTexts["game-capture-setting"].value as? String ?? "").hasPrefix("Enabled for this game"))
        let spacePicker = app.popUpButtons["game-fullscreen-space-picker"]
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: spacePicker)
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 15), .completed)
        spacePicker.click(); app.menuItems["Use fullscreen Space"].click()
        let space = app.staticTexts["game-fullscreen-presentation"]
        let saved = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value CONTAINS %@", "Dedicated fullscreen Space"), object: space)
        XCTAssertEqual(XCTWaiter.wait(for: [saved], timeout: 15), .completed)
        app.terminate(); app.launch(); openSettings()
        XCTAssertTrue((space.value as? String ?? "").contains("Dedicated fullscreen Space"))
        let unlocked = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: spacePicker)
        XCTAssertEqual(XCTWaiter.wait(for: [unlocked], timeout: 15), .completed)
        spacePicker.click(); app.menuItems["Keep on desktop"].click()
        let reverted = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value CONTAINS %@", "Effective next launch: Desktop"), object: space)
        XCTAssertEqual(XCTWaiter.wait(for: [reverted], timeout: 15), .completed)
        let registry = try String(contentsOf: prefix.appendingPathComponent("user.reg"), encoding: .utf8)
        XCTAssertTrue(registry.contains("custom.exe"))
        XCTAssertFalse(registry.contains(GameFixtures.primary.executable))
    }

    func testEmptyLauncherCacheCleanup() async throws {
        let root = try temporaryRoot()
        _ = try EnvironmentStore(root: root)
        let probe = root.appendingPathComponent("Launchers/Games/1234")
        try FileManager.default.createDirectory(at: probe, withIntermediateDirectories: true)
        let current = root.appendingPathComponent("Launchers/Games/526870/shared-pe-v2")
        try FileManager.default.createDirectory(at: current, withIntermediateDirectories: true)
        let app = XCUIApplication()
        app.launchArguments = ["--metadata-root", root.path, "--ui-test-scenario", "ready"]
        app.launch()
        defer { app.terminate() }
        openLaunchers(in: app)
        XCTAssertTrue(app.staticTexts["Ready to install and launch"].waitForExistence(timeout: 20))
        showResetOptions(in: app)
        let inspect = app.buttons["inspect-launcher-caches"]
        revealRecoveryButton(inspect, in: app); inspect.click()
        let remove = app.buttons["clean-launcher-cache-original/1234"]
        XCTAssertTrue(remove.waitForExistence(timeout: 10))
        revealRecoveryButton(remove, in: app); remove.click()
        let sheet = app.windows["Gamekit"].sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 5))
        sheet.buttons["Cancel"].click()
        XCTAssertTrue(FileManager.default.fileExists(atPath: probe.path))
        remove.click()
        XCTAssertTrue(sheet.waitForExistence(timeout: 5))
        sheet.buttons["Remove obsolete cache"].click()
        let done = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "Obsolete launcher cache removed."), object: app.staticTexts["launcher-caches-status"])
        XCTAssertEqual(XCTWaiter.wait(for: [done], timeout: 15), .completed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: probe.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: current.path))
    }

    func testRecoveryArchiveInspectionCancelAndCleanup() async throws {
        let root = try temporaryRoot()
        let store = try EnvironmentStore(root: root)
        let id = SteamInstallationRecipe.environmentID
        _ = try await store.create(EnvironmentRecord(id: id, name: "Archive cleanup fixture", runtime: RuntimeProfile.sikarugir.identity,
            installation: .installed, installationRecipeVersion: 1))
        let steam = store.prefixURL(for: id).appendingPathComponent("drive_c/Program Files (x86)/Steam")
        try FileManager.default.createDirectory(at: steam.appendingPathComponent("steamapps"), withIntermediateDirectories: true)
        try Data("game".utf8).write(to: steam.appendingPathComponent("steamapps/game.bin"))
        try Data("old client".utf8).write(to: steam.appendingPathComponent("Steam.exe"))
        let recovery = SteamRecovery(store: store, driver: .init(observe: { _, _ in .init(processes: [], complete: true) }, stop: { _, _, _ in }))
        _ = try await recovery.resetPreservingDownloads(confirmed: true)
        try FileManager.default.createDirectory(at: steam, withIntermediateDirectories: true)
        try SteamRecoveryArchive.restoreLibraries(root: root, id: id)
        try Data("new client".utf8).write(to: steam.appendingPathComponent("Steam.exe"))
        let savedRecord = try await store.load(id)
        var record = try XCTUnwrap(savedRecord)
        record.installation = .installed
        _ = try await store.save(record)
        let archives = try await recovery.archives()
        let archive = try XCTUnwrap(archives.first)
        let archivedPrefix = root.appendingPathComponent("Recovery/steam/\(archive.id)/prefix")
        let app = XCUIApplication()
        app.launchArguments = ["--metadata-root", root.path, "--ui-test-scenario", "ready"]
        app.launch()
        defer { app.terminate() }
        openLaunchers(in: app)
        XCTAssertTrue(app.staticTexts["Archive cleanup fixture"].waitForExistence(timeout: 20))
        showResetOptions(in: app)
        let inspect = app.buttons["inspect-recovery-archives"]
        revealRecoveryButton(inspect, in: app)
        inspect.click()
        let cleanup = app.buttons["clean-recovery-archive-\(archive.id)"]
        XCTAssertTrue(cleanup.waitForExistence(timeout: 15))
        revealRecoveryButton(cleanup, in: app)
        cleanup.click()
        let confirmation = app.windows["Gamekit"].sheets.firstMatch
        XCTAssertTrue(confirmation.waitForExistence(timeout: 5))
        confirmation.buttons["Cancel"].click()
        XCTAssertTrue(FileManager.default.fileExists(atPath: archivedPrefix.path))
        cleanup.click()
        XCTAssertTrue(confirmation.waitForExistence(timeout: 5))
        confirmation.buttons["Delete archived prefix"].click()
        let status = app.staticTexts["recovery-archives-status"]
        let completed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value BEGINSWITH %@", "Archived prefix cleaned."), object: status)
        XCTAssertEqual(XCTWaiter.wait(for: [completed], timeout: 20), .completed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: archivedPrefix.path))
        XCTAssertEqual(try Data(contentsOf: steam.appendingPathComponent("steamapps/game.bin")), Data("game".utf8))
    }

    func testGraphicsBackendPersistsThroughAppRestartAndCanRevert() async throws {
        let root = try temporaryRoot()
        let app = XCUIApplication()
        app.launchArguments = ["--metadata-root", root.path, "--ui-test-scenario", "ready"]
        app.launch()
        defer { app.terminate() }
        openLaunchers(in: app)
        let picker = app.popUpButtons["graphics-backend-picker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 20))
        revealRecoveryButton(picker, in: app)
        picker.click()
        XCTAssertTrue(app.menuItems["DXVK (Direct3D 10/11) — Not installed"].exists)
        XCTAssertTrue(app.menuItems["DXMT (Direct3D 10/11) — Not installed"].exists)
        XCTAssertFalse(app.menuItems["DXVK (Direct3D 10/11) — Not installed"].isEnabled)
        XCTAssertFalse(app.menuItems["DXMT (Direct3D 10/11) — Not installed"].isEnabled)
        app.menuItems["Metal 3 compatibility"].click()
        let selected = app.staticTexts["selected-graphics-backend"]
        let saved = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value CONTAINS %@", "Metal 3 compatibility"), object: selected)
        XCTAssertEqual(XCTWaiter.wait(for: [saved], timeout: 15), .completed)
        let store = try EnvironmentStore(root: root)
        let layout = try await RuntimeSettingsStore(store: store).layout()
        XCTAssertEqual(layout.graphicsBackend, .metal3)
        XCTAssertTrue((app.staticTexts["graphics-backend-scope"].value as? String ?? "").contains("all games"))
        app.terminate()
        app.launch(); openLaunchers(in: app)
        XCTAssertTrue(selected.waitForExistence(timeout: 20))
        let restored = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value CONTAINS %@", "Metal 3 compatibility"), object: selected)
        XCTAssertEqual(XCTWaiter.wait(for: [restored], timeout: 15), .completed)
        revealRecoveryButton(picker, in: app)
        picker.click()
        app.menuItems["Automatic (Apple default)"].click()
        let reverted = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value CONTAINS %@", "Automatic"), object: selected)
        XCTAssertEqual(XCTWaiter.wait(for: [reverted], timeout: 15), .completed)
        let automaticLayout = try await RuntimeSettingsStore(store: store).layout()
        XCTAssertEqual(automaticLayout.graphicsBackend, .automatic)
    }

    func testGraphicsBackendControlsAreLockedByRecordedSession() async throws {
        let root = try temporaryRoot()
        let directory = root.appendingPathComponent("Metadata/Lifecycle")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: directory.appendingPathComponent("steam.json"))
        let app = XCUIApplication()
        app.launchArguments = ["--metadata-root", root.path, "--ui-test-scenario", "ready"]
        app.launch()
        defer { app.terminate() }
        openLaunchers(in: app)
        XCTAssertTrue(app.staticTexts["Ready to install and launch"].waitForExistence(timeout: 20))
        XCTAssertFalse(app.popUpButtons["graphics-backend-picker"].isEnabled)
    }

    func testInstalledGamesRefreshAndUnavailableLaunch() async throws {
        let root = try temporaryRoot()
        let store = try EnvironmentStore(root: root)
        let id = SteamInstallationRecipe.environmentID
        _ = try await store.create(EnvironmentRecord(id: id, name: "Game library fixture", runtime: RuntimeProfile.sikarugir.identity,
            installation: .installed, installationRecipeVersion: 1))
        let steam = store.prefixURL(for: id).appendingPathComponent("drive_c/Program Files (x86)/Steam")
        let apps = steam.appendingPathComponent("steamapps")
        try FileManager.default.createDirectory(at: apps.appendingPathComponent("common/Stardew Valley"), withIntermediateDirectories: true)
        try Data("fixture".utf8).write(to: steam.appendingPathComponent("Steam.exe"))
        try Data("WINE REGISTRY Version 2\n".utf8).write(to: store.prefixURL(for: id).appendingPathComponent("user.reg"))
        let manifest = apps.appendingPathComponent("appmanifest_413150.acf")
        try Data(#""AppState" { "appid" "413150" "name" "Stardew Valley" "installdir" "Stardew Valley" "StateFlags" "4" "SizeOnDisk" "123456789" }"#.utf8).write(to: manifest)
        let app = XCUIApplication()
        app.launchArguments = ["--metadata-root", root.path, "--ui-test-scenario", "invalid-runtime"]
        app.launch()
        defer { app.terminate() }
        openGameInspector(413150, in: app)
        let game = app.buttons["launch-game-413150"]
        XCTAssertTrue(game.waitForExistence(timeout: 20))
        XCTAssertEqual(game.label, "Play")
        let reported = ByteCountFormatter.string(fromByteCount: 123_456_789, countStyle: .file)
        XCTAssertTrue(app.staticTexts["Steam-reported size: \(reported)"].exists)
        XCTAssertFalse(game.isEnabled, "Unavailable runtime must disable game launches")
        let uninstall = app.buttons["uninstall-game-413150"]
        XCTAssertTrue(uninstall.exists)
        XCTAssertFalse(uninstall.isEnabled, "Unavailable runtime must also disable Steam uninstall requests")
        app.buttons["game-compatibility-413150"].click()
        XCTAssertTrue(app.staticTexts["game-profile-source"].waitForExistence(timeout: 5))
        let cursorGuard = app.descendants(matching: .any)["game-cursor-guard"]
        XCTAssertTrue(cursorGuard.exists)
        XCTAssertTrue(app.buttons["Update profile"].exists)
        app.buttons["Done"].click()
        try FileManager.default.removeItem(at: manifest)
        XCTAssertTrue(app.staticTexts["games-empty"].waitForExistence(timeout: 15))
        XCTAssertFalse(game.exists, "Uninstalled games must disappear after polling")
    }

    func testProfileJSONImportExportAndAutomaticRestore() async throws {
        let root = try temporaryRoot()
        let store = try EnvironmentStore(root: root)
        let game = GameFixtures.other
        _ = try await store.create(.init(id: SteamInstallationRecipe.environmentID, name: "Profile transfer fixture",
            runtime: RuntimeProfile.sikarugir.identity, installation: .installed, installationRecipeVersion: 1))
        let steam = store.prefixURL(for: SteamInstallationRecipe.environmentID).appendingPathComponent(RelativePath.steamDefault.rawValue).deletingLastPathComponent()
        try FileManager.default.createDirectory(at: steam.appendingPathComponent("steamapps/common/" + game.name), withIntermediateDirectories: true)
        try Data("fixture".utf8).write(to: steam.appendingPathComponent("Steam.exe"))
        try game.manifest.write(to: steam.appendingPathComponent("steamapps/appmanifest_\(game.appId).acf"))
        let profiles = GameProfileStore(root: store.root)
        let template = try await profiles.exportProfile(appID: game.appId, name: game.name)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: template) as? [String: Any])
        object["notes"] = "Manually imported UI fixture."
        let input = root.appendingPathComponent("manual.json")
        try JSONSerialization.data(withJSONObject: object).write(to: input)
        let app = XCUIApplication()
        app.launchArguments = ["--metadata-root", root.path, "--ui-test-scenario", "invalid-runtime"]
        app.launch()
        defer { app.terminate() }
        openGameInspector(game.appId, in: app)
        let gear = app.buttons["game-compatibility-\(game.appId)"]
        XCTAssertTrue(gear.waitForExistence(timeout: 20))
        gear.click()
        let importButton = app.buttons["import-game-profile"]
        XCTAssertTrue(importButton.waitForExistence(timeout: 10))
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: importButton)
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 15), .completed)
        importButton.click()
        let openPanel = app.sheets["open-panel"]
        XCTAssertTrue(openPanel.waitForExistence(timeout: 10))
        app.typeKey("g", modifierFlags: [.command, .shift])
        app.typeText(input.path)
        app.typeKey(.return, modifierFlags: [])
        openPanel.buttons["OKButton"].click()
        let restored = app.buttons["restore-automatic-game-profile"]
        XCTAssertTrue(restored.waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["Manually imported UI fixture."].exists)
        app.buttons["export-game-profile"].click()
        let savePanel = app.sheets["save-panel"]
        XCTAssertTrue(savePanel.waitForExistence(timeout: 10))
        let filename = savePanel.textFields.firstMatch
        filename.click(); filename.typeKey("a", modifierFlags: .command); filename.typeText("exported.json")
        app.typeKey("g", modifierFlags: [.command, .shift])
        app.typeText(root.path)
        app.typeKey(.return, modifierFlags: [])
        savePanel.buttons["OKButton"].click()
        let output = root.appendingPathComponent("exported.json")
        for _ in 0..<50 {
            if FileManager.default.fileExists(atPath: output.path) { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        let exported = try GameProfile.decode(Data(contentsOf: output), appID: game.appId)
        XCTAssertEqual(exported.notes, "Manually imported UI fixture.")
        restored.click()
        let automatic = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: restored)
        XCTAssertEqual(XCTWaiter.wait(for: [automatic], timeout: 15), .completed)
        XCTAssertNotEqual(GameProfileStore.resolved(appID: game.appId, root: store.root)?.isLocal, true)
    }

    func testUninstallConfirmationCancelBusyGateAndLibraryRefresh() async throws {
        let root = try temporaryRoot()
        let store = try EnvironmentStore(root: root)
        let id = SteamInstallationRecipe.environmentID
        _ = try await store.create(EnvironmentRecord(id: id, name: "Uninstall UI fixture", runtime: RuntimeProfile.sikarugir.identity,
            installation: .installed, installationRecipeVersion: 1))
        let layout = RuntimeLayout(dataRoot: root)
        for file in [layout.wine, layout.wineserver] {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("non-executable fixture".utf8).write(to: file)
        }
        let steam = store.prefixURL(for: id).appendingPathComponent(RelativePath.steamDefault.rawValue).deletingLastPathComponent()
        let apps = steam.appendingPathComponent("steamapps")
        try FileManager.default.createDirectory(at: apps.appendingPathComponent("common/Fixture"), withIntermediateDirectories: true)
        try Data("fixture".utf8).write(to: steam.appendingPathComponent("Steam.exe"))
        let manifest = apps.appendingPathComponent("appmanifest_42.acf")
        let original = Data(#""AppState" { "appid" "42" "name" "Uninstall Fixture" "installdir" "Fixture" "StateFlags" "1026" }"#.utf8)
        try original.write(to: manifest)
        let app = XCUIApplication()
        app.launchArguments = ["--metadata-root", root.path, "--ui-test-scenario", "ready-with-delay"]
        app.launch()
        defer { app.terminate() }
        openGameInspector(42, in: app)
        let uninstall = app.buttons["uninstall-game-42"]
        XCTAssertTrue(uninstall.waitForExistence(timeout: 20))
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: uninstall)
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 20), .completed)
        XCTAssertFalse(app.buttons["launch-game-42"].isEnabled, "Incomplete installs can be uninstalled but not played")
        revealRecoveryButton(uninstall, in: app)
        uninstall.click()
        let dialog = app.windows["Gamekit"].sheets.firstMatch
        XCTAssertTrue(dialog.waitForExistence(timeout: 5))
        XCTAssertTrue(dialog.staticTexts["Uninstall Uninstall Fixture?"].exists)
        XCTAssertTrue(dialog.buttons["Continue in Windows Steam"].exists)
        dialog.buttons["Cancel"].click()
        XCTAssertEqual(try Data(contentsOf: manifest), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Metadata/Lifecycle/steam.json").path), "Cancel must not launch Steam or send a request")
        openLaunchers(in: app)
        app.typeKey("r", modifierFlags: [.command, .shift])
        XCTAssertTrue(app.staticTexts["Checking prerequisites"].waitForExistence(timeout: 5))
        app.buttons["library-all"].click()
        XCTAssertFalse(uninstall.isEnabled)
        openLaunchers(in: app)
        XCTAssertTrue(app.staticTexts["Ready to install and launch"].waitForExistence(timeout: 15))
        try FileManager.default.removeItem(at: manifest)
        app.buttons["library-all"].click()
        XCTAssertTrue(app.staticTexts["games-empty"].waitForExistence(timeout: 15))
        XCTAssertFalse(uninstall.exists)
    }

    func testOptInPackagedAppLaunchQuitReopenStop() async throws {
        guard ProcessInfo.processInfo.environment["GAMEKIT_PACKAGE_UI_SMOKE"] == "1" else { throw XCTSkip("Opt-in packaged app lifecycle") }
        let path = try XCTUnwrap(ProcessInfo.processInfo.environment["GAMEKIT_PACKAGE_APP"])
        let app = XCUIApplication(url: URL(fileURLWithPath: path))
        app.launch()
        openLaunchers(in: app)
        XCTAssertTrue(app.staticTexts["Ready to install and launch"].waitForExistence(timeout: 45))
        XCTAssertTrue(app.staticTexts["Steam: stopped"].waitForExistence(timeout: 15))
        let launch = app.buttons["launch-steam"]
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: launch)
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 15), .completed)
        launch.click()
        XCTAssertTrue(app.staticTexts["Steam: running"].waitForExistence(timeout: 60))
        app.activate()
        app.typeKey("q", modifierFlags: .command)
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 5))
        _ = try await ProcessExecutor().run(.init(executable: URL(fileURLWithPath: "/usr/bin/open"), arguments: [path]))
        openLaunchers(in: app)
        XCTAssertTrue(app.staticTexts["Steam: running"].waitForExistence(timeout: 45))
        let stop = app.buttons["stop-steam"]
        let stoppable = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: stop)
        XCTAssertEqual(XCTWaiter.wait(for: [stoppable], timeout: 15), .completed)
        stop.click()
        XCTAssertTrue(app.staticTexts["Steam: stopped"].waitForExistence(timeout: 90))
        app.terminate()
    }

    func testPrerequisiteFailuresDisableInstallAndExplainNextSteps() throws {
        for (scenario, explanation) in [("missing-rosetta", "Install Rosetta using Apple's instructions, then refresh checks. Gamekit does not accept its license for you."),
                                        ("low-disk", "Keep at least 15 GiB free on the app-data volume. Review old archives and free space, then refresh."),
                                        ("invalid-runtime", "Choose the validated runtime app with its packaged dependencies. A generic Wine app is not interchangeable.")] {
            let app = XCUIApplication()
            app.launchArguments = ["--metadata-root", try temporaryRoot().path, "--ui-test-scenario", scenario]
            app.launch()
            openLaunchers(in: app)
            XCTAssertTrue(app.staticTexts[explanation].waitForExistence(timeout: 15))
            XCTAssertFalse(app.buttons["install-steam"].isEnabled)
            app.terminate()
        }
    }

    func testRefreshEnablesInstallAfterPrerequisitesAreCorrected() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--metadata-root", try temporaryRoot().path, "--ui-test-scenario", "ready-after-refresh"]
        app.launch()
        defer { app.terminate() }
        openLaunchers(in: app)
        XCTAssertTrue(app.staticTexts["Resolve the checks below before installation"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["install-steam"].isEnabled)
        let refresh = app.buttons["refresh-prerequisites"]
        revealRecoveryButton(refresh, in: app)
        refresh.click()
        XCTAssertTrue(app.staticTexts["Ready to install and launch"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["install-steam"].isEnabled)
    }

    func testKeyboardRefreshDisablesConflictingActionsUntilChecksComplete() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--metadata-root", try temporaryRoot().path, "--ui-test-scenario", "ready-with-delay"]
        app.launch()
        defer { app.terminate() }
        openLaunchers(in: app)
        XCTAssertTrue(app.staticTexts["Ready to install and launch"].waitForExistence(timeout: 15))
        app.activate()
        app.typeKey("r", modifierFlags: [.command, .shift])
        XCTAssertTrue(app.staticTexts["Checking prerequisites"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["install-steam"].isEnabled)
        XCTAssertFalse(app.buttons["refresh-prerequisites"].isEnabled)
        XCTAssertTrue(app.staticTexts["Ready to install and launch"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["install-steam"].isEnabled)
    }

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
        openLaunchers(in: app)
        XCTAssertTrue(app.staticTexts["Disposable clean reset"].waitForExistence(timeout: 15))
        showResetOptions(in: app)
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
        openLaunchers(in: app)
        XCTAssertTrue(app.staticTexts["Steam: running"].waitForExistence(timeout: 60))
        app.activate()
        app.typeKey("q", modifierFlags: .command)
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 5), "Normal Quit must not wait for Steam shutdown")
        let opened = try await ProcessExecutor().run(.init(executable: URL(fileURLWithPath: "/usr/bin/open"), arguments: [appPath], timeout: 10))
        XCTAssertEqual(opened.termination, .exited(0))
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10), "Ordinary Launch Services reopen must work while Steam remains alive")
        openLaunchers(in: app)
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
        showResetOptions(in: app)
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
        openLaunchers(in: app)
        let running = app.staticTexts["Steam: running"]
        XCTAssertTrue(running.waitForExistence(timeout: 60))
        let receiptURL = store.root.appendingPathComponent("Metadata/Lifecycle/steam.json")
        let receiptBeforeQuit = try Data(contentsOf: receiptURL)
        app.terminate()
        // Xcode's UI runner may not inspect another process's kernel arguments.
        // The relaunched app must observe the existing session without a launch flag.
        app.launchArguments = ["--metadata-root", root, "--diagnostics-root", logs.path]
        app.launch()
        openLaunchers(in: app)
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
        app.buttons["nav-diagnostics"].click()
        XCTAssertTrue(app.buttons["export-diagnostic-\(summary.id.uuidString)"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["local-diagnostic-\(summary.id.uuidString)"].exists)
        let exported = try await store.exportSummary(summary.id)
        XCTAssertFalse(String(decoding: exported, as: UTF8.self).contains("PRIVATE_UI_DIAGNOSTIC"))
    }

    func testUnreadableLibraryKeepsSelectionAndRoutesToDiagnostics() async throws {
        let root = try temporaryRoot()
        let store = try EnvironmentStore(root: root)
        let id = SteamInstallationRecipe.environmentID
        _ = try await store.create(.init(id: id, name: "Library warning fixture", runtime: RuntimeProfile.sikarugir.identity,
                                         installation: .installed, installationRecipeVersion: 1))
        let steam = store.prefixURL(for: id).appendingPathComponent(RelativePath.steamDefault.rawValue).deletingLastPathComponent()
        try FileManager.default.createDirectory(at: steam.appendingPathComponent("steamapps/common/Fixture"), withIntermediateDirectories: true)
        try Data("fixture".utf8).write(to: steam.appendingPathComponent("Steam.exe"))
        try Data(#""AppState" { "appid" "42" "name" "Fixture" "installdir" "Fixture" "StateFlags" "4" }"#.utf8)
            .write(to: steam.appendingPathComponent("steamapps/appmanifest_42.acf"))
        try Data("invalid receipt".utf8).write(to: steam.appendingPathComponent("steamapps/appmanifest_43.acf"))
        let app = XCUIApplication()
        app.launchArguments = ["--metadata-root", root.path, "--ui-test-scenario", "invalid-runtime"]
        app.launch(); defer { app.terminate() }
        let warning = app.staticTexts["persistent-library-warning"]
        XCTAssertTrue(warning.waitForExistence(timeout: 20))
        let tile = app.buttons["select-game-42"]
        XCTAssertTrue(tile.waitForExistence(timeout: 10))
        tile.click()
        XCTAssertFalse(app.buttons["launch-game-42"].isEnabled, "Unreadable records make the library stale")
        app.buttons["library-diagnostics-link"].click()
        XCTAssertTrue(app.staticTexts["diagnostics-heading"].waitForExistence(timeout: 10))
        XCTAssertTrue(warning.exists, "The actionable warning must survive navigation")
        app.buttons["library-all"].click()
        XCTAssertTrue(tile.waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["launch-game-42"].exists, "The selected installation survives diagnostics routing")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Metadata/Lifecycle/steam.json").path))
    }

    private func temporaryRoot() throws -> URL {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: parent) }
        return parent.appendingPathComponent("Gamekit")
    }

    private func openLaunchers(in app: XCUIApplication) {
        let button = app.buttons["nav-launchers"]
        XCTAssertTrue(button.waitForExistence(timeout: 15))
        button.click()
        XCTAssertTrue(app.staticTexts["launchers-heading"].waitForExistence(timeout: 15))
    }

    private func openGameInspector(_ appID: UInt32, in app: XCUIApplication) {
        let tile = app.buttons["select-game-\(appID)"]
        XCTAssertTrue(tile.waitForExistence(timeout: 20))
        tile.click()
        XCTAssertTrue(app.buttons["game-compatibility-\(appID)"].waitForExistence(timeout: 10))
    }

    private func revealRecoveryButton(_ button: XCUIElement, in app: XCUIApplication) {
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: button)
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 20), .completed)
        if button.isHittable && app.windows["Gamekit"].frame.insetBy(dx: 0, dy: 8).contains(button.frame) { return }
        let scroll = app.scrollViews.firstMatch
        // A partially clipped button can report hittable while its center is
        // outside the scroll viewport. Avoid clicking during startup layout shifts.
        for _ in 0..<12 {
            if button.isHittable && scroll.frame.insetBy(dx: 0, dy: 16).contains(button.frame) { return }
            scroll.scroll(byDeltaX: 0, deltaY: button.frame.midY < scroll.frame.minY ? 160 : -160)
        }
        XCTAssertTrue(button.isHittable && scroll.frame.contains(button.frame), button.debugDescription)
    }

    private func showResetOptions(in app: XCUIApplication) {
        openLaunchers(in: app)
        let button = app.buttons["show-reset-options"]
        XCTAssertTrue(button.waitForExistence(timeout: 15))
        revealRecoveryButton(button, in: app)
        button.click()
    }

    func testNativeAppLaunchesWithLinkedCore() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--metadata-root", try temporaryRoot().path]
        app.launch()
        defer { app.terminate() }

        XCTAssertTrue(app.windows["Gamekit"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["library-heading"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["games-empty"].exists)
        openLaunchers(in: app)
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
            openLaunchers(in: app)
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
        openLaunchers(in: app)
        XCTAssertTrue(app.staticTexts["metadata-error"].waitForExistence(timeout: 10))
        XCTAssertEqual(try Data(contentsOf: path), original)
    }
}
