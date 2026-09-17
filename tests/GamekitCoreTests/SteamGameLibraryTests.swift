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
    func manifest(_ id: String = "413150", flags: String = "4", directory: String = "Stardew Valley", createFiles: Bool = true) throws {
        let text = "\"AppState\" { \"appid\" \"\(id)\" \"name\" \"Stardew Valley\" \"StateFlags\" \"\(flags)\" \"installdir\" \"\(directory)\" \"buildid\" \"16826371\" \"InstalledDepots\" { \"413151\" { \"manifest\" \"4278718763097142923\" } } }"
        try Data(text.utf8).write(to: steam.appendingPathComponent("steamapps/appmanifest_\(id).acf"))
        if createFiles { try FileManager.default.createDirectory(at: steam.appendingPathComponent("steamapps/common/\(directory)"), withIntermediateDirectories: true) }
    }
}

@Suite("Installed Windows Steam games")
struct SteamGameLibraryTests {
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
