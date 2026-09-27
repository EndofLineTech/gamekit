import Foundation
import Testing
@testable import GamekitCore

private struct GameLibraryFixture {
    let prefix: URL
    let steam: URL
    init() throws {
        prefix = try ManagedDirectory.canonicalRoot(FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        steam = prefix.appendingPathComponent("drive_c/Program Files (x86)/Steam")
        try FileManager.default.createDirectory(at: steam.appendingPathComponent("steamapps/common"), withIntermediateDirectories: true)
    }
    func remove() { try? FileManager.default.removeItem(at: prefix) }
    func manifest(_ id: String = "413150", name: String = "Stardew Valley", flags: String = "4", directory: String = "Stardew Valley", createFiles: Bool = true, sizeOnDisk: String? = nil) throws {
        let size = sizeOnDisk.map { "\"SizeOnDisk\" \"\($0)\"" } ?? ""
        let text = "\"AppState\" { \"appid\" \"\(id)\" \"name\" \"\(name)\" \"StateFlags\" \"\(flags)\" \"installdir\" \"\(directory)\" \"buildid\" \"16826371\" \(size) \"InstalledDepots\" { \"413151\" { \"manifest\" \"4278718763097142923\" } } }"
        try Data(text.utf8).write(to: steam.appendingPathComponent("steamapps/appmanifest_\(id).acf"))
        if createFiles { try FileManager.default.createDirectory(at: steam.appendingPathComponent("steamapps/common/\(directory)"), withIntermediateDirectories: true) }
    }
}

@Suite("Installed Windows Steam games")
struct SteamGameLibraryTests {
    @Test("Presentation IDs distinguish same-title Steam installations and survive a new scan")
    func presentationIdentity() throws {
        let fixture = try GameLibraryFixture(); defer { fixture.remove() }
        try fixture.manifest("111", name: "Shared title", directory: "first")
        try fixture.manifest("222", name: "Shared title", directory: "second")
        let environment = try EnvironmentID("windows-steam")
        let entries = try SteamGameLibrary.scan(prefix: fixture.prefix).games.map {
            SteamLibraryGame(installed: $0, environmentID: environment)
        }
        #expect(entries.count == 2)
        #expect(entries[0].title == entries[1].title)
        #expect(entries[0].id != entries[1].id)
        #expect(Set(entries.map(\.id)).count == 2)
        #expect(entries[0].source == .windowsSteam)
        #expect(entries[0].state == .ready)
        #expect(entries[0].reportedSizeBytes == nil)
        #expect(entries.map(\.id) == (try SteamGameLibrary.scan(prefix: fixture.prefix).games.map {
            SteamLibraryGame(installed: $0, environmentID: environment).id
        }))
        #expect(SteamGameInstallationID(environmentID: try EnvironmentID("another-steam"), appID: 111) != entries[0].id)
        let encoded = try JSONEncoder().encode(entries[0].id)
        #expect(String(decoding: encoded, as: UTF8.self).contains("windows-steam"))
        #expect(!String(decoding: encoded, as: UTF8.self).contains("first"))
        #expect(try JSONDecoder().decode(SteamGameInstallationID.self, from: encoded) == entries[0].id)
    }

    @Test("Presentation preserves reported bytes, header and incomplete or missing-file states")
    func presentationState() throws {
        let fixture = try GameLibraryFixture(); defer { fixture.remove() }
        let environment = try EnvironmentID("steam")
        try fixture.manifest(sizeOnDisk: "0")
        let cache = fixture.steam.appendingPathComponent("appcache/librarycache/413150")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: cache.appendingPathComponent("header.jpg"))
        func entry() throws -> SteamLibraryGame {
            SteamLibraryGame(installed: try #require(SteamGameLibrary.scan(prefix: fixture.prefix).games.first), environmentID: environment)
        }
        let ready = try entry()
        #expect(ready.reportedSizeBytes == 0)
        #expect(ready.landscapeHeader == Data([1, 2, 3]))
        try fixture.manifest(flags: "1026", sizeOnDisk: "100")
        let updating = try entry()
        #expect(updating.id == ready.id && updating.state == .updating && updating.reportedSizeBytes == nil)
        try fixture.manifest(flags: "4", createFiles: false, sizeOnDisk: "100")
        try FileManager.default.removeItem(at: fixture.steam.appendingPathComponent("steamapps/common/Stardew Valley"))
        let missing = try entry()
        #expect(missing.id == ready.id && missing.state == .missingFiles && missing.reportedSizeBytes == nil)
    }

    @Test("Discovers installed game identity and local artwork, then reflects uninstall")
    func installedAndRemoved() throws {
        let fixture = try GameLibraryFixture(); defer { fixture.remove() }
        try fixture.manifest()
        let cache = fixture.steam.appendingPathComponent("appcache/librarycache/413150")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: cache.appendingPathComponent("header.jpg"))
        let game = try #require(SteamGameLibrary.scan(prefix: fixture.prefix).games.first)
        #expect(game.id == 413150 && game.name == "Stardew Valley")
        #expect(game.buildID == "16826371" && game.state == .ready)
        #expect(game.artwork == Data([1, 2, 3]))
        try FileManager.default.removeItem(at: fixture.steam.appendingPathComponent("steamapps/appmanifest_413150.acf"))
        #expect(try SteamGameLibrary.scan(prefix: fixture.prefix).games.isEmpty)
    }

    @Test("Incomplete downloads, pending updates and missing directories are not launchable")
    func incomplete() throws {
        let fixture = try GameLibraryFixture(); defer { fixture.remove() }
        for flags in ["0", "2", "6", "1026", "1048576", "2052", "132"] {
            try fixture.manifest(flags: flags)
            #expect(try SteamGameLibrary.scan(prefix: fixture.prefix).games.first?.state == .updating)
        }
        try fixture.manifest(flags: "68")
        #expect(try SteamGameLibrary.scan(prefix: fixture.prefix).games.first?.state == .ready)
        try FileManager.default.removeItem(at: fixture.steam.appendingPathComponent("steamapps/common/Stardew Valley"))
        #expect(try SteamGameLibrary.scan(prefix: fixture.prefix).games.first?.state == .missingFiles)
    }

    @Test("Steam-reported installed bytes are optional and never an estimate for missing or incomplete files")
    func diskUsage() throws {
        let fixture = try GameLibraryFixture(); defer { fixture.remove() }
        try fixture.manifest(sizeOnDisk: "65663762225")
        #expect(try SteamGameLibrary.scan(prefix: fixture.prefix).games.first?.sizeOnDiskBytes == 65_663_762_225)
        for value in [nil, "not-a-number", "-1", "9223372036854775808"] as [String?] {
            try fixture.manifest(sizeOnDisk: value)
            #expect(try SteamGameLibrary.scan(prefix: fixture.prefix).games.first?.sizeOnDiskBytes == nil)
        }
        try fixture.manifest(flags: "1026", sizeOnDisk: "65663762225")
        #expect(try SteamGameLibrary.scan(prefix: fixture.prefix).games.first?.sizeOnDiskBytes == nil)
        try fixture.manifest(flags: "4", createFiles: false, sizeOnDisk: "65663762225")
        try FileManager.default.removeItem(at: fixture.steam.appendingPathComponent("steamapps/common/Stardew Valley"))
        #expect(try SteamGameLibrary.scan(prefix: fixture.prefix).games.first?.sizeOnDiskBytes == nil)
    }

    @Test("Malformed or redirecting manifests cannot hide valid games or create launch targets")
    func hostileEntries() throws {
        let fixture = try GameLibraryFixture(); defer { fixture.remove() }
        try fixture.manifest()
        try fixture.manifest("526870", directory: "../escape", createFiles: false)
        try fixture.manifest("228980", directory: "Steamworks Shared")
        let apps = fixture.steam.appendingPathComponent("steamapps")
        try Data("\"AppState\" { \"appid\" \"1\"".utf8).write(to: apps.appendingPathComponent("appmanifest_1.acf"))
        try FileManager.default.createSymbolicLink(at: apps.appendingPathComponent("appmanifest_2.acf"), withDestinationURL: apps.appendingPathComponent("appmanifest_413150.acf"))
        let result = try SteamGameLibrary.scan(prefix: fixture.prefix)
        #expect(result.games.map(\.id) == [413150])
        #expect(result.unreadableManifests == 3)
    }

    @Test("A symlinked common directory is rejected")
    func redirectedLibrary() throws {
        let fixture = try GameLibraryFixture(); defer { fixture.remove() }
        try fixture.manifest(createFiles: false)
        let common = fixture.steam.appendingPathComponent("steamapps/common")
        try FileManager.default.removeItem(at: common)
        try FileManager.default.createSymbolicLink(at: common, withDestinationURL: fixture.prefix)
        #expect(throws: EnvironmentStoreError.unsafePath) { try SteamGameLibrary.scan(prefix: fixture.prefix) }
    }

    @Test("KeyValues parses comments, escaped quotes and nested fields but refuses ambiguity")
    func keyValues() throws {
        let parsed = try SteamKeyValues.parse(Data(#"""
        // comment
        "AppState" { "name" "A \"quoted\" game" "nested" { "name" "wrong" } }
        """#.utf8))
        #expect(parsed["appstate"]?.object?["name"]?.string == "A \"quoted\" game")
        for text in ["\"x\" {", "\"x\" \"1\" \"X\" \"2\"", "\"x\" \"unterminated", "\"x\" {} }"] {
            #expect(throws: SteamGameLibraryError.invalidManifest) { try SteamKeyValues.parse(Data(text.utf8)) }
        }
    }

    @Test("Oversized and excessively nested records fail closed")
    func boundedParsing() throws {
        #expect(throws: SteamGameLibraryError.invalidManifest) {
            try SteamKeyValues.parse(Data(repeating: 32, count: 1_048_577))
        }
        let nested = String(repeating: "\"section\" {", count: 18) + String(repeating: "}", count: 18)
        #expect(throws: SteamGameLibraryError.invalidManifest) { try SteamKeyValues.parse(Data(nested.utf8)) }
    }

    @Test("An AppID mismatch is rejected and a new download does not need a common directory")
    func mismatchedIdentity() throws {
        let fixture = try GameLibraryFixture(); defer { fixture.remove() }
        try fixture.manifest(flags: "1048576", createFiles: false)
        #expect(try SteamGameLibrary.scan(prefix: fixture.prefix).games.first?.state == .updating)
        let apps = fixture.steam.appendingPathComponent("steamapps")
        try FileManager.default.moveItem(at: apps.appendingPathComponent("appmanifest_413150.acf"),
                                        to: apps.appendingPathComponent("appmanifest_526870.acf"))
        let result = try SteamGameLibrary.scan(prefix: fixture.prefix)
        #expect(result.games.isEmpty && result.unreadableManifests == 1)
    }

    @Test("Read-only inspection of the real managed library", .enabled(if: ProcessInfo.processInfo.environment["GAMEKIT_LIBRARY_INSPECTION"] == "1"))
    func liveLibrary() async throws {
        let store = try EnvironmentStore()
        let record = try #require(await store.load(SteamInstallationRecipe.environmentID))
        let result = try SteamGameLibrary.scan(prefix: store.prefixURL(for: record.id), steamExecutable: record.steamExecutable)
        #expect(result.unreadableManifests == 0)
        for game in result.games {
            print("Managed library: AppID=\(game.id), build=\(game.buildID ?? "unknown"), state=\(game.state.rawValue), cachedArtwork=\(game.artwork != nil)")
        }
        print("Managed library count: \(result.games.count)")
    }
}
