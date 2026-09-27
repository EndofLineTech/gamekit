import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import GamekitCore

private actor ArtworkRequests {
    private(set) var urls: [URL] = []
    private(set) var active = 0
    private(set) var peak = 0
    func fetch(_ url: URL, bytes: Data) async throws -> Data {
        urls.append(url)
        active += 1
        peak = max(peak, active)
        defer { active -= 1 }
        try await Task.sleep(for: .milliseconds(40))
        return bytes
    }
}

private func portraitFixture() throws -> Data {
    let width = 60, height = 90
    let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                         bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(red: 0.3, green: 0.6, blue: 0.8, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let image = try #require(context.makeImage())
    let result = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(result, "public.png" as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    #expect(CGImageDestinationFinalize(destination))
    return result as Data
}

@Suite("Bounded Steam portrait artwork")
struct SteamPortraitArtworkTests {
    @Test("A local portrait is distinct from the landscape header and never requests the network")
    func cachedPortrait() async throws {
        let prefix = try ManagedDirectory.canonicalRoot(FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        defer { try? FileManager.default.removeItem(at: prefix) }
        let steam = prefix.appendingPathComponent("drive_c/Program Files (x86)/Steam")
        let local = steam.appendingPathComponent("appcache/librarycache/\(GameFixtures.other.appId)")
        let apps = steam.appendingPathComponent("steamapps/common/")
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: apps.appendingPathComponent("local-art"), withIntermediateDirectories: true)
        let bytes = try portraitFixture()
        try bytes.write(to: local.appendingPathComponent("library_600x900.jpg"))
        try Data([1, 2, 3]).write(to: local.appendingPathComponent("header.jpg"))
        try GameFixtures.other.manifest(directory: "local-art").write(to: steam.appendingPathComponent("steamapps/appmanifest_\(GameFixtures.other.appId).acf"))
        let header = try #require(SteamGameLibrary.scan(prefix: prefix).games.first?.artwork)
        #expect(header == Data([1, 2, 3]))
        let requests = ArtworkRequests()
        let cache = SteamPortraitArtworkCache(prefix: prefix, remote: { url in try await requests.fetch(url, bytes: bytes) })
        let id = SteamGameInstallationID(environmentID: SteamInstallationRecipe.environmentID, appID: GameFixtures.other.appId)
        #expect(await cache.portrait(for: id) == bytes)
        #expect(await requests.urls.isEmpty)
        #expect(try SteamGameLibrary.scan(prefix: prefix).games.first?.artwork == header)
    }

    @Test("Remote portraits are scoped to Steam AppIDs, cached, bounded and cancellable")
    func remotePortrait() async throws {
        let prefix = try ManagedDirectory.canonicalRoot(FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let bytes = try portraitFixture()
        let requests = ArtworkRequests()
        let cache = SteamPortraitArtworkCache(prefix: prefix, remote: { url in try await requests.fetch(url, bytes: bytes) })
        let id = SteamGameInstallationID(environmentID: SteamInstallationRecipe.environmentID, appID: GameFixtures.other.appId)
        #expect(await cache.portrait(for: id) == bytes)
        #expect(await cache.portrait(for: id) == bytes)
        let urls = await requests.urls
        #expect(urls.count == 1)
        #expect(urls.first?.absoluteString == "https://cdn.akamai.steamstatic.com/steam/apps/\(GameFixtures.other.appId)/library_600x900.jpg")
        let foreign = SteamGameInstallationID(environmentID: try EnvironmentID("other"), appID: id.appID)
        #expect(await cache.portrait(for: foreign) == nil)
        #expect(await requests.urls.count == 1)
        await withTaskGroup(of: Data?.self) { group in
            for offset in 1...12 {
                let next = SteamGameInstallationID(environmentID: id.environmentID, appID: id.appID + UInt32(offset))
                group.addTask { await cache.portrait(for: next) }
            }
            for await result in group { #expect(result == bytes) }
        }
        #expect(await requests.peak <= 4)
        let delayed = SteamPortraitArtworkCache(prefix: prefix, remote: { _ in
            try await Task.sleep(for: .seconds(2))
            return bytes
        })
        let task = Task { await delayed.portrait(for: id) }
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()
        #expect(await task.value == nil)
    }

    @Test("Offline, corrupt, oversized and landscape data yield an empty portrait, never a launch blocker")
    func rejectedArtwork() async throws {
        let prefix = try ManagedDirectory.canonicalRoot(FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        defer { try? FileManager.default.removeItem(at: prefix) }
        let id = SteamGameInstallationID(environmentID: SteamInstallationRecipe.environmentID, appID: GameFixtures.other.appId)
        let offline = SteamPortraitArtworkCache(prefix: prefix, remote: { _ in throw URLError(.notConnectedToInternet) })
        #expect(await offline.portrait(for: id) == nil)
        for bytes in [Data([1, 2, 3]), Data(repeating: 1, count: SteamPortraitArtworkCache.maximumBytes + 1)] {
            let invalid = SteamPortraitArtworkCache(prefix: prefix, remote: { _ in bytes })
            #expect(await invalid.portrait(for: id) == nil)
        }
        let local = prefix.appendingPathComponent("drive_c/Program Files (x86)/Steam/appcache/librarycache/\(id.appID)")
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        let file = local.appendingPathComponent("library_600x900.jpg")
        let valid = try portraitFixture()
        let requests = ArtworkRequests()
        for corrupt in [Data([1, 2, 3]), Data(repeating: 1, count: SteamPortraitArtworkCache.maximumBytes + 1)] {
            try corrupt.write(to: file)
            let fallback = SteamPortraitArtworkCache(prefix: prefix, remote: { url in try await requests.fetch(url, bytes: valid) })
            #expect(await fallback.portrait(for: id) == valid)
        }
        #expect(await requests.urls.count == 2)
    }
}
