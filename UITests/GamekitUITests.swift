@testable import GamekitCore
import XCTest

@MainActor
final class GamekitUITests: XCTestCase {
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
            let gear = app.buttons["game-compatibility-123456"]
            XCTAssertTrue(gear.waitForExistence(timeout: 20)); revealRecoveryButton(gear, in: app); gear.click()
            XCTAssertTrue(app.popUpButtons["game-graphics-backend-picker"].waitForExistence(timeout: 15))
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
    func testDebugCaptureIsOptInAndResetsWhenAppReopens() throws {
        let root = try temporaryRoot()
        let app = XCUIApplication()
        app.launchArguments = ["--metadata-root", root.path, "--ui-test-scenario", "ready"]
        app.launch()
        defer { app.terminate() }
        let toggle = app.checkBoxes["debug-performance-mode"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 20))
        revealRecoveryButton(toggle, in: app)
        XCTAssertEqual(toggle.value as? Int, 0)
        toggle.click()
        XCTAssertEqual(toggle.value as? Int, 1)
        XCTAssertFalse(app.buttons["stop-debug-capture"].isEnabled)
        app.terminate(); app.launch()
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
        try FileManager.default.createDirectory(at: steam.appendingPathComponent("steamapps/common/Helldivers"), withIntermediateDirectories: true)
        try Data("fixture".utf8).write(to: steam.appendingPathComponent("Steam.exe"))
        try Data(#""AppState" { "appid" "553850" "name" "Helldivers" "installdir" "Helldivers" "StateFlags" "4" }"#.utf8).write(to: steam.appendingPathComponent("steamapps/appmanifest_553850.acf"))
        try Data("WINE REGISTRY Version 2\n#arch=win64\n".utf8).write(to: prefix.appendingPathComponent("user.reg"))
        let app = XCUIApplication()
        app.launchArguments = ["--metadata-root", root.path, "--ui-test-scenario", "ready"]
        app.launch()
        defer { app.terminate() }
        func openSettings() {
            let open = app.buttons["game-compatibility-553850"]
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
        XCTAssertTrue(app.sheets.firstMatch.popUpButtons["game-graphics-backend-picker"].exists)
        change("enable-game-capture", expected: "Enabled for this game")
        change("disable-game-capture", expected: "Disabled for this game")
        change("restore-game-defaults", expected: "Inherit Wine default")
        change("enable-game-capture", expected: "Enabled for this game")
        app.terminate(); app.launch()
        openSettings()
        XCTAssertTrue((app.staticTexts["game-capture-setting"].value as? String ?? "").hasPrefix("Enabled for this game"))
        let spaceButton = app.buttons["enable-fullscreen-space"]
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: spaceButton)
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 15), .completed)
        spaceButton.click()
        let space = app.staticTexts["game-fullscreen-presentation"]
        let saved = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "Dedicated fullscreen Space"), object: space)
        XCTAssertEqual(XCTWaiter.wait(for: [saved], timeout: 15), .completed)
        app.terminate(); app.launch(); openSettings()
        XCTAssertEqual(space.value as? String, "Dedicated fullscreen Space")
        let desktop = app.buttons["disable-fullscreen-space"]
        let unlocked = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: desktop)
        XCTAssertEqual(XCTWaiter.wait(for: [unlocked], timeout: 15), .completed)
        desktop.click()
        let reverted = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "Fullscreen on the desktop"), object: space)
        XCTAssertEqual(XCTWaiter.wait(for: [reverted], timeout: 15), .completed)
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
        app.launch()
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
        let manifest = apps.appendingPathComponent("appmanifest_413150.acf")
        try Data(#""AppState" { "appid" "413150" "name" "Stardew Valley" "installdir" "Stardew Valley" "StateFlags" "4" }"#.utf8).write(to: manifest)
        let app = XCUIApplication()
        app.launchArguments = ["--metadata-root", root.path, "--ui-test-scenario", "invalid-runtime"]
        app.launch()
        defer { app.terminate() }
        let game = app.buttons["launch-game-413150"]
        XCTAssertTrue(game.waitForExistence(timeout: 20))
        XCTAssertEqual(game.label, "Launch Stardew Valley")
        XCTAssertFalse(game.isEnabled, "Unavailable runtime must disable game launches")
        let uninstall = app.buttons["uninstall-game-413150"]
        XCTAssertTrue(uninstall.exists)
        XCTAssertFalse(uninstall.isEnabled, "Unavailable runtime must also disable Steam uninstall requests")
        try FileManager.default.removeItem(at: manifest)
        XCTAssertTrue(app.staticTexts["games-empty"].waitForExistence(timeout: 15))
        XCTAssertFalse(game.exists, "Uninstalled games must disappear after polling")
    }

    func testControllersPanelExplainsHostInputAndRequiresSteamSetup() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--metadata-root", try temporaryRoot().path, "--ui-test-scenario", "ready"]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.staticTexts["Ready to install and launch"].waitForExistence(timeout: 20))
        let disclosure = app.disclosureTriangles.firstMatch
        XCTAssertTrue(disclosure.waitForExistence(timeout: 5))
        revealRecoveryButton(disclosure, in: app)
        disclosure.click()
        let settings = app.buttons["steam-controller-settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        XCTAssertFalse(settings.isEnabled, "A host controller does not replace managed Steam setup")
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "does not yet prove input reaches a Windows game")).firstMatch.exists)
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
        app.typeKey("r", modifierFlags: [.command, .shift])
        XCTAssertTrue(app.staticTexts["Checking prerequisites"].waitForExistence(timeout: 5))
        XCTAssertFalse(uninstall.isEnabled)
        XCTAssertTrue(app.staticTexts["Ready to install and launch"].waitForExistence(timeout: 15))
        try FileManager.default.removeItem(at: manifest)
        XCTAssertTrue(app.staticTexts["games-empty"].waitForExistence(timeout: 15))
        XCTAssertFalse(uninstall.exists)
    }

    func testOptInPackagedAppLaunchQuitReopenStop() async throws {
        guard ProcessInfo.processInfo.environment["GAMEKIT_PACKAGE_UI_SMOKE"] == "1" else { throw XCTSkip("Opt-in packaged app lifecycle") }
        let path = try XCTUnwrap(ProcessInfo.processInfo.environment["GAMEKIT_PACKAGE_APP"])
        let app = XCUIApplication(url: URL(fileURLWithPath: path))
        app.launch()
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
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: button)
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 20), .completed)
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
