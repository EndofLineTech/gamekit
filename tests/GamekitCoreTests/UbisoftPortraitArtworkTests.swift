import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import Testing
@testable import GamekitCore

private actor UbisoftArtworkRequests {
    private(set) var urls: [URL] = []
    var unavailable = false

    func fetch(_ url: URL, bytes: Data) throws -> Data {
        urls.append(url)
        if unavailable { throw URLError(.notConnectedToInternet) }
        return bytes
    }

    func setUnavailable() { unavailable = true }
}

private func packshotFixture(width: Int = 464, height: Int = 608, format: String = "public.jpeg") throws -> Data {
    let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                         bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(red: 0.25, green: 0.45, blue: 0.65, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let image = try #require(context.makeImage())
    let bytes = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(bytes, format as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    #expect(CGImageDestinationFinalize(destination))
    return bytes as Data
}

private func fixtureProfile(image: Data) throws -> UbisoftArtworkProfile {
    let official = try UbisoftArtworkProfile.bundled()
    let cover = try #require(official.covers.first { $0.gameID == GameFixtures.ubisoftCatalog.id })
    let sha256 = SHA256.hash(data: image).map { String(format: "%02x", $0) }.joined()
    let document: [String: Any] = ["schemaVersion": 1, "launcherID": official.launcherID.rawValue,
        "covers": [["gameID": cover.gameID, "sourcePage": cover.sourcePage.absoluteString,
                    "role": cover.role, "imageURL": cover.imageURL.absoluteString, "sha256": sha256]]]
    return try UbisoftArtworkProfile.decode(JSONSerialization.data(withJSONObject: document))
}

@Suite("Verified Ubisoft Store portrait artwork")
struct UbisoftPortraitArtworkTests {
    @Test("The bundled official Store page explicitly maps the installed Ubisoft ID to a packshot")
    func bundledMapping() throws {
        let profile = try UbisoftArtworkProfile.bundled()
        let cover = try #require(profile.covers.first { $0.gameID == GameFixtures.ubisoftCatalog.id })
        #expect(cover.role == "edition_packshot")
        #expect(cover.sourcePage.host == "store.ubisoft.com")
        #expect(cover.imageURL.host == cover.sourcePage.host)
        #expect(cover.imageURL.lastPathComponent == cover.sourcePage.deletingPathExtension().lastPathComponent + ".jpg")
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["GAMEKIT_TEST_PUBLIC_ARTWORK"] == "1"))
    func liveOfficialPackshot() async throws {
        let cache = try UbisoftPortraitArtworkCache()
        let image = await cache.portrait(for: GameFixtures.ubisoftCatalog.id)
        #expect(image != nil, "The public Ubisoft Store image must match the pinned identity and portrait bounds")
    }

    @Test("Only pinned, correctly shaped portraits from mapped Ubisoft IDs are cached")
    func validAndOffline() async throws {
        let bytes = try packshotFixture()
        let profile = try fixtureProfile(image: bytes)
        let cover = try #require(profile.covers.first)
        let requests = UbisoftArtworkRequests()
        let cache = UbisoftPortraitArtworkCache(profile: profile, remote: { try await requests.fetch($0, bytes: bytes) })
        #expect(await cache.portrait(for: cover.gameID) == bytes)
        await requests.setUnavailable()
        #expect(await cache.portrait(for: cover.gameID) == bytes)
        #expect(await cache.portrait(for: cover.gameID + 1) == nil)
        #expect(await requests.urls == [cover.imageURL])

        let offline = UbisoftPortraitArtworkCache(profile: profile, remote: { _ in throw URLError(.notConnectedToInternet) })
        #expect(await offline.portrait(for: cover.gameID) == nil)
    }

    @Test("Wrong bytes, overlarge images, landscape headers and malformed images never become covers")
    func invalidImages() async throws {
        let valid = try packshotFixture()
        let id = GameFixtures.ubisoftCatalog.id
        let invalid = [Data([1, 2, 3]), Data(repeating: 1, count: UbisoftPortraitArtworkCache.maximumBytes + 1),
                       try packshotFixture(width: 608, height: 464), try packshotFixture(format: "public.png")]
        for bytes in invalid {
            let profile = try fixtureProfile(image: bytes)
            let cache = UbisoftPortraitArtworkCache(profile: profile, remote: { _ in bytes })
            #expect(await cache.portrait(for: id) == nil)
        }
        let badHash = try fixtureProfile(image: Data("different".utf8))
        let mismatched = UbisoftPortraitArtworkCache(profile: badHash, remote: { _ in valid })
        #expect(await mismatched.portrait(for: id) == nil)
    }

    @Test("Source URLs, duplicate identities and unverified roles fail profile validation")
    func invalidMappings() throws {
        let official = try UbisoftArtworkProfile.bundled()
        let cover = try #require(official.covers.first)
        func changed(_ mutate: (inout [String: Any]) -> Void) throws -> Data {
            var values: [String: Any] = ["schemaVersion": 1, "launcherID": official.launcherID.rawValue,
                "covers": [["gameID": cover.gameID, "sourcePage": cover.sourcePage.absoluteString,
                            "role": cover.role, "imageURL": cover.imageURL.absoluteString, "sha256": cover.sha256]]]
            mutate(&values)
            return try JSONSerialization.data(withJSONObject: values)
        }
        let invalid = try [changed { values in
                               let covers = values["covers"] as! [[String: Any]]
                               values["covers"] = [covers[0], covers[0]]
                           },
                           changed { values in
                               var covers = values["covers"] as! [[String: Any]]
                               covers[0]["role"] = "landscape"
                               values["covers"] = covers
                           },
                           changed { values in
                               var covers = values["covers"] as! [[String: Any]]
                               covers[0]["imageURL"] = "https://unrelated.example/images/large/\(cover.sourcePage.deletingPathExtension().lastPathComponent).jpg"
                               values["covers"] = covers
                           },
                           changed { values in
                               var covers = values["covers"] as! [[String: Any]]
                               covers[0]["imageURL"] = cover.imageURL.absoluteString + "?tracking=1"
                               values["covers"] = covers
                           },
                           changed { values in
                               var covers = values["covers"] as! [[String: Any]]
                               covers[0]["sourcePage"] = "https://store.ubisoft.com/us/other/111111111111111111111111.html"
                               values["covers"] = covers
                           }]
        for data in invalid {
            #expect(throws: UbisoftGameCatalogError.invalidRecord) { try UbisoftArtworkProfile.decode(data) }
        }
    }
}
