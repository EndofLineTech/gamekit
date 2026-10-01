import Foundation
import Testing
@testable import GamekitCore

private actor CatalogFixtureQueries {
    let fixture = GameFixtures.ubisoftCatalog
    let profile = try! LauncherProfileStore.bundled("ubisoft")
    var unavailable = false
    var partial = false
    var requestedIDs: [UInt32] = []

    func setUnavailable(_ value: Bool) { unavailable = value }
    func setPartial(_ value: Bool) { partial = value }
    func query(_ key: String) throws -> String {
        if unavailable { throw ManagedLauncherLifecycleError.observationUnavailable }
        let catalog = profile.gameCatalog!
        if key == catalog.installsRegistryKey {
            return partial ? fixture.installs + fixture.installs.replacingOccurrences(of: String(fixture.id), with: String(fixture.id + 1))
                : fixture.installs
        }
        if key == catalog.uninstallRegistryKey + "\\" + catalog.uninstallKeyPrefix + String(fixture.id) {
            return fixture.uninstall
        }
        throw UbisoftGameCatalogError.invalidRecord
    }
    func launch(_ id: UInt32) { requestedIDs.append(id) }
}

@Suite("Registered Ubisoft installation discovery")
struct UbisoftGameCatalogTests {
    @Test("Matched vendor keys, owned game markers and icon survive an idle refresh without fabricated Play")
    func installedAndCached() async throws {
        let data = GameFixtures.ubisoftCatalog
        let profile = try LauncherProfileStore.bundled("ubisoft")
        let catalog = try #require(profile.gameCatalog)
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: parent) }
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let store = try EnvironmentStore(root: parent.appendingPathComponent("Gamekit"))
        let layout = RuntimeLayout(dataRoot: store.root)
        _ = try await store.create(EnvironmentRecord(id: profile.id, name: profile.name,
            runtime: layout.profile.identity,
            installer: .init(source: profile.installer.url, sha256: profile.installer.sha256, downloadedAt: Date()),
            steamExecutable: profile.executable, installation: .installed, installationRecipeVersion: 1))
        let prefix = store.prefixURL(for: profile.id)
        let executable = prefix.appendingPathComponent(profile.executable.rawValue)
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("launcher fixture".utf8).write(to: executable)
        let folder = prefix.appendingPathComponent(catalog.gamesDirectory.rawValue).appendingPathComponent(data.folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for marker in catalog.installMarkers { try Data("owned install".utf8).write(to: folder.appendingPathComponent(marker)) }
        let icons = prefix.appendingPathComponent(catalog.iconDirectory.rawValue)
        try FileManager.default.createDirectory(at: icons, withIntermediateDirectories: true)
        let icon = Data("bounded icon fixture".utf8)
        try icon.write(to: icons.appendingPathComponent(data.iconName))

        let driver = CatalogFixtureQueries()
        let service = UbisoftGameCatalog(store: store, layout: layout, profile: profile,
            registry: { try await driver.query($0) }, launch: { await driver.launch($0) })
        let current = try await service.scan()
        #expect(current.current && current.unreadableRecords == 0)
        let game = try #require(current.games.first)
        #expect(current.games.count == 1 && game.id == data.id && game.name == data.name)
        #expect(game.state == .installed && game.icon == icon)
        try await service.requestPlay(data.id)
        #expect(await driver.requestedIDs == [data.id])
        await #expect(throws: UbisoftGameCatalogError.unavailable) { try await service.requestPlay(data.id + 1) }
        #expect(await driver.requestedIDs == [data.id])

        await driver.setUnavailable(true)
        let cached = try await service.scan()
        #expect(!cached.current && cached.games == current.games)
        await #expect(throws: UbisoftGameCatalogError.unavailable) { try await service.requestPlay(data.id) }
        let cacheURL = store.root.appendingPathComponent("Metadata/\(profile.id.rawValue)-Games.json")
        await driver.setUnavailable(false)
        await driver.setPartial(true)
        let partial = try await service.scan()
        #expect(!partial.current && partial.unreadableRecords == 1 && partial.games == current.games)
        await #expect(throws: UbisoftGameCatalogError.unavailable) { try await service.requestPlay(data.id) }
        await driver.setPartial(false)
        try Data("invalid cache".utf8).write(to: cacheURL)
        #expect(try await service.scan().games == current.games, "A fresh owned scan replaces a corrupt cache")
        await driver.setUnavailable(true)
        var saved = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: cacheURL)) as? [String: Any])
        saved["prefixDevice"] = try #require(saved["prefixDevice"] as? Int) + 1
        try JSONSerialization.data(withJSONObject: saved).write(to: cacheURL)
        #expect(try await service.scan().games.isEmpty, "A remounted or replaced prefix cannot inherit the old cache")
        await driver.setUnavailable(false)
        #expect(try await service.scan().games == current.games, "A fresh owned registry scan renews the cache")
        await driver.setUnavailable(true)
        try FileManager.default.removeItem(at: folder.appendingPathComponent(catalog.installMarkers[0]))
        let unfinished = try await service.scan()
        #expect(unfinished.games.first?.state == .incomplete)
        #expect(try Data(contentsOf: executable) == Data("launcher fixture".utf8))
        let displaced = parent.appendingPathComponent("displaced-game")
        try FileManager.default.moveItem(at: folder, to: displaced)
        try FileManager.default.createSymbolicLink(at: folder, withDestinationURL: displaced)
        await driver.setUnavailable(false)
        await #expect(throws: EnvironmentStoreError.unsafePath) { try await service.scan() }
    }

    @Test("Mismatched registry paths, duplicate IDs, traversal and malformed titles never become a launch record")
    func refuseContradictions() throws {
        let profile = try LauncherProfileStore.bundled("ubisoft")
        let catalog = try #require(profile.gameCatalog)
        let data = GameFixtures.ubisoftCatalog
        let parsed = try UbisoftGameCatalog.installEntries(data.installs, spec: catalog)
        #expect(parsed.values.count == 1 && parsed.rejected == 0)
        let install = try #require(parsed.values[data.id])
        let found = try UbisoftGameCatalog.record(id: data.id, installedAt: install, uninstall: data.uninstall, spec: catalog)
        #expect(found.folder == data.folder && found.iconName == data.iconName)
        #expect(try UbisoftGameCatalog.installEntries(data.installs + data.installs, spec: catalog).rejected == 1)
        #expect(try UbisoftGameCatalog.installEntries(data.installs.replacingOccurrences(of: "Installs\\\(data.id)", with: "Installs\\../../"), spec: catalog).rejected == 1)
        for changed in [data.uninstall.replacingOccurrences(of: "DisplayName    REG_SZ    \(data.name)", with: "DisplayName    REG_SZ    \u{0001}"),
                        data.uninstall.replacingOccurrences(of: "Publisher    REG_SZ    Ubisoft", with: "Publisher    REG_SZ    Unknown"),
                        data.uninstall.replacingOccurrences(of: "games/\(data.folder)/", with: "games/other/")] {
            #expect(throws: UbisoftGameCatalogError.invalidRecord) {
                try UbisoftGameCatalog.record(id: data.id, installedAt: install, uninstall: changed, spec: catalog)
            }
        }
        #expect(throws: UbisoftGameCatalogError.invalidRecord) {
            try UbisoftGameCatalog.record(id: data.id, installedAt: "C:/outside/\(data.folder)/", uninstall: data.uninstall, spec: catalog)
        }
    }
}
