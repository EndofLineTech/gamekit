import CryptoKit
import Foundation
import Testing
@testable import GamekitCore

private struct ApplicationBundleFixture {
    let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let layout: RuntimeLayout
    init() throws {
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let root = try EnvironmentStore(root: parent.appendingPathComponent("Gamekit")).root
        let wine = Data("wine fixture".utf8), server = Data("server fixture".utf8)
        func hash(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }
        layout = .init(dataRoot: root, profile: .init(identity: RuntimeProfile.sikarugir.identity, bundlePath: "Runtimes/fixture.app", wineVersionOutput: "fixture", hashes: [
            "Contents/SharedSupport/wine/bin/wine": hash(wine), "Contents/SharedSupport/wine/bin/wineserver": hash(server)
        ]))
        try FileManager.default.createDirectory(at: layout.wine.deletingLastPathComponent(), withIntermediateDirectories: true)
        try wine.write(to: layout.wine); try server.write(to: layout.wineserver)
    }
    func remove() { try? FileManager.default.removeItem(at: parent) }
}

@Suite("Windows Steam application identity")
struct SteamApplicationBundleTests {
    @Test("The derived launcher preserves source bytes and is reused without replacement")
    func immutableSourceAndReuse() async throws {
        let fixture = try ApplicationBundleFixture(); defer { fixture.remove() }
        let builder = SteamApplicationBundle(layout: fixture.layout)
        let bundle = try await builder.prepare()
        let directory = try #require(try ManagedDirectory.openRoot(bundle, create: false))
        let identity = try directory.identity()
        #expect(try Data(contentsOf: fixture.layout.wine) == Data("wine fixture".utf8))
        #expect(try Data(contentsOf: bundle.appendingPathComponent("Contents/MacOS/Windows Steam")) == Data(contentsOf: fixture.layout.wine))
        #expect(try await builder.prepare() == bundle)
        let reopened = try #require(try ManagedDirectory.openRoot(bundle, create: false))
        #expect(try reopened.identity() == identity)
    }
    @Test("An altered existing launcher is refused rather than overwritten")
    func modifiedCache() async throws {
        let fixture = try ApplicationBundleFixture(); defer { fixture.remove() }
        let builder = SteamApplicationBundle(layout: fixture.layout)
        let bundle = try await builder.prepare()
        let binary = bundle.appendingPathComponent("Contents/MacOS/Windows Steam")
        try Data("changed".utf8).write(to: binary)
        await #expect(throws: SteamApplicationError.invalidBundle) { try await builder.prepare() }
        #expect(try Data(contentsOf: binary) == Data("changed".utf8))
    }
    @Test("A redirected launcher root cannot write outside managed storage")
    func redirectedRoot() async throws {
        let fixture = try ApplicationBundleFixture(); defer { fixture.remove() }
        let outside = fixture.parent.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: fixture.layout.dataRoot.appendingPathComponent("Launchers"), withDestinationURL: outside)
        await #expect(throws: EnvironmentStoreError.unsafePath) { try await SteamApplicationBundle(layout: fixture.layout).prepare() }
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
    }

    @Test("Runtime symlinks are copied literally and failed staging cleanup never follows them")
    func copiedLinksAndCleanup() async throws {
        let fixture = try ApplicationBundleFixture(); defer { fixture.remove() }
        let outside = fixture.parent.appendingPathComponent("preserve")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let marker = outside.appendingPathComponent("marker")
        try Data("outside".utf8).write(to: marker)
        let library = fixture.layout.engine.appendingPathComponent("lib/nested")
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: library.appendingPathComponent("link"), withDestinationURL: outside)
        try Data("modified server".utf8).write(to: fixture.layout.wineserver)
        await #expect(throws: SteamApplicationError.invalidBundle) { try await SteamApplicationBundle(layout: fixture.layout).prepare() }
        #expect(try Data(contentsOf: marker) == Data("outside".utf8))
        let names = try FileManager.default.contentsOfDirectory(atPath: fixture.layout.dataRoot.appendingPathComponent("Launchers").path)
        #expect(names == [".windows-steam.lock"])
    }
}
