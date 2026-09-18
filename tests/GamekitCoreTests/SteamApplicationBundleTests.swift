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
        let pe = layout.engine.appendingPathComponent("lib/wine/x86_64-windows")
        try FileManager.default.createDirectory(at: pe, withIntermediateDirectories: true)
        try Data("shared PE image".utf8).write(to: pe.appendingPathComponent("ntdll.dll"))
    }
    func remove() { try? FileManager.default.removeItem(at: parent) }
    func legacyGame() async throws -> URL {
        let current = try await SteamApplicationBundle(layout: layout, game: .init(appID: 526870, name: "Satisfactory")).prepare()
        let legacy = current.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Satisfactory.app")
        try FileManager.default.copyItem(at: current, to: legacy)
        let manifest = legacy.appendingPathComponent("Contents/Gamekit-runtime.json")
        var value = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as? [String: Any])
        value["format"] = 1
        try JSONSerialization.data(withJSONObject: value).write(to: manifest)
        return legacy
    }
}

@Suite("Windows Steam application identity")
struct SteamApplicationBundleTests {
    @Test("Only the Helldivers driver revision gets a private DXGI; other PE images remain shared")
    func scopedDriverShim() async throws {
        let fixture = try ApplicationBundleFixture(); defer { fixture.remove() }
        let basePath = "Contents/SharedSupport/wine/"
        let dxgi = basePath + "lib/wine/x86_64-windows/dxgi.dll"
        let shim = basePath + "lib/gamekit/helldivers-dxgi.dll"
        let original = Data("original DXGI".utf8), replacement = Data("game scoped shim".utf8)
        try original.write(to: fixture.layout.bundle.appendingPathComponent(dxgi))
        try FileManager.default.createDirectory(at: fixture.layout.bundle.appendingPathComponent(shim).deletingLastPathComponent(), withIntermediateDirectories: true)
        try replacement.write(to: fixture.layout.bundle.appendingPathComponent(shim))
        var hashes = fixture.layout.profile.hashes
        for (name, data) in [(dxgi, original), (shim, replacement)] {
            hashes[name] = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
        let profile = RuntimeProfile(identity: fixture.layout.profile.identity, bundlePath: "unused", wineVersionOutput: "fixture", hashes: hashes, revision: .driverVersion1)
        let layout = RuntimeLayout(dataRoot: fixture.layout.dataRoot, profile: profile, bundle: fixture.layout.bundle)
        let steam = try await SteamApplicationBundle(layout: layout).prepare()
        let builder = SteamApplicationBundle(layout: layout, game: .init(appID: 553850, name: "Helldivers"))
        let game = try await builder.prepare()
        let other = try await SteamApplicationBundle(layout: layout, game: .init(appID: 526870, name: "Satisfactory")).prepare()
        let relative = "Contents/lib/wine/x86_64-windows/"
        #expect(try Data(contentsOf: steam.appendingPathComponent(relative + "dxgi.dll")) == original)
        #expect(try Data(contentsOf: other.appendingPathComponent(relative + "dxgi.dll")) == original)
        #expect(try Data(contentsOf: game.appendingPathComponent(relative + "dxgi.dll")) == replacement)
        #expect(try Data(contentsOf: fixture.layout.bundle.appendingPathComponent(dxgi)) == original)
        func inode(_ root: URL, _ file: String) throws -> NSNumber? {
            try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent(relative + file).path)[.systemFileNumber] as? NSNumber
        }
        #expect(try inode(steam, "ntdll.dll") == inode(game, "ntdll.dll"))
        #expect(try inode(steam, "dxgi.dll") == inode(other, "dxgi.dll"))
        #expect(try inode(steam, "dxgi.dll") != inode(game, "dxgi.dll"))
        #expect(try await builder.prepare() == game)
        try Data("tampered".utf8).write(to: game.appendingPathComponent(relative + "dxgi.dll"))
        await #expect(throws: SteamApplicationError.invalidBundle) { try await builder.prepare() }
        #expect(try Data(contentsOf: steam.appendingPathComponent(relative + "dxgi.dll")) == original)
    }
    @Test("Only validated legacy caches are removable; current PE caches and source bytes survive")
    func obsoleteCacheCleanup() async throws {
        let fixture = try ApplicationBundleFixture(); defer { fixture.remove() }
        let legacy = try await fixture.legacyGame()
        let store = try EnvironmentStore(root: fixture.layout.dataRoot)
        let maintenance = LauncherCacheMaintenance(store: store, layouts: [fixture.layout], idle: { true })
        let entries = try await maintenance.inspect()
        let old = try #require(entries.first(where: { $0.status == .obsolete }))
        #expect(entries.contains { $0.status == .retained && !$0.canClean })
        await #expect(throws: SteamRecoveryError.confirmationRequired) { try await maintenance.clean(old, confirmed: false) }
        #expect(FileManager.default.fileExists(atPath: legacy.path))
        try await maintenance.clean(old, confirmed: true)
        #expect(!FileManager.default.fileExists(atPath: legacy.path))
        let current = SteamApplicationBundle(layout: fixture.layout, game: .init(appID: 526870, name: "Satisfactory"))
        try current.validate(current.bundleURL)
        #expect(try Data(contentsOf: fixture.layout.wine) == Data("wine fixture".utf8))
        #expect(try await maintenance.inspect().allSatisfy { !$0.canClean })
    }

    @Test("Stale selection and unrecognized cache contents cannot authorize cleanup")
    func changedLegacyCache() async throws {
        let fixture = try ApplicationBundleFixture(); defer { fixture.remove() }
        let legacy = try await fixture.legacyGame()
        let store = try EnvironmentStore(root: fixture.layout.dataRoot)
        let maintenance = LauncherCacheMaintenance(store: store, layouts: [fixture.layout], idle: { true })
        let old = try #require(try await maintenance.inspect().first(where: { $0.status == .obsolete }))
        try Data("changed".utf8).write(to: legacy.appendingPathComponent("Contents/MacOS/Satisfactory"))
        await #expect(throws: SteamApplicationError.invalidBundle) { try await maintenance.clean(old, confirmed: true) }
        #expect(try await maintenance.inspect().contains { $0.status == .protected })
        #expect(FileManager.default.fileExists(atPath: legacy.path))
    }

    @Test("Empty probe parents can be removed; running or uncertain launchers prevent deletion", arguments: [true, false, nil] as [Bool?])
    func emptyCacheParent(stopped: Bool?) async throws {
        let fixture = try ApplicationBundleFixture(); defer { fixture.remove() }
        let probe = fixture.layout.gameApplicationsRoot.appendingPathComponent("1234")
        try FileManager.default.createDirectory(at: probe, withIntermediateDirectories: true)
        let store = try EnvironmentStore(root: fixture.layout.dataRoot)
        let maintenance = LauncherCacheMaintenance(store: store, layouts: [fixture.layout], idle: { stopped })
        let entry = try #require(try await maintenance.inspect().first)
        #expect(entry.status == .empty)
        if stopped == true {
            try await maintenance.clean(entry, confirmed: true)
            #expect(!FileManager.default.fileExists(atPath: probe.path))
        } else {
            await #expect(throws: (any Error).self) { try await maintenance.clean(entry, confirmed: true) }
            #expect(FileManager.default.fileExists(atPath: probe.path))
        }
    }

    @Test("Persistent session receipts block cache maintenance")
    func cacheReceiptLock() async throws {
        let fixture = try ApplicationBundleFixture(); defer { fixture.remove() }
        _ = try await fixture.legacyGame()
        let store = try EnvironmentStore(root: fixture.layout.dataRoot)
        let maintenance = LauncherCacheMaintenance(store: store, layouts: [fixture.layout], idle: { true })
        let entry = try #require(try await maintenance.inspect().first(where: { $0.canClean }))
        let lifecycle = store.root.appendingPathComponent("Metadata/Lifecycle")
        try FileManager.default.createDirectory(at: lifecycle, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: lifecycle.appendingPathComponent("steam.json"))
        await #expect(throws: EnvironmentStoreError.busy) { try await maintenance.clean(entry, confirmed: true) }
    }

    @Test("A journaled partial cache deletion is retryable without following external links")
    func resumeCacheCleanup() async throws {
        let fixture = try ApplicationBundleFixture(); defer { fixture.remove() }
        let legacy = try await fixture.legacyGame()
        let outside = fixture.parent.appendingPathComponent("outside-save")
        try Data("keep".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: legacy.appendingPathComponent("external-link"), withDestinationURL: outside)
        let store = try EnvironmentStore(root: fixture.layout.dataRoot)
        let maintenance = LauncherCacheMaintenance(store: store, layouts: [fixture.layout], idle: { true })
        let entry = try #require(try await maintenance.inspect().first(where: { $0.status == .obsolete }))
        let ticket = legacy.deletingLastPathComponent().appendingPathComponent(".cleanup-Satisfactory.app.json")
        try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "name": "Satisfactory.app", "device": entry.device, "inode": entry.inode]).write(to: ticket)
        try FileManager.default.removeItem(at: legacy.appendingPathComponent("Contents/MacOS/Satisfactory"))
        let pending = try #require(try await maintenance.inspect().first(where: { $0.status == .cleanupPending }))
        try await maintenance.clean(pending, confirmed: true)
        #expect(try Data(contentsOf: outside) == Data("keep".utf8))
        #expect(!FileManager.default.fileExists(atPath: ticket.path))
        #expect(!FileManager.default.fileExists(atPath: legacy.path))
    }

    @Test("Inspect real launcher caches without deleting anything", .enabled(if: ProcessInfo.processInfo.environment["GAMEKIT_INSPECT_CACHES"] == "1"))
    func inspectLiveCaches() async throws {
        let maintenance = LauncherCacheMaintenance(store: try EnvironmentStore())
        let entries = try await maintenance.inspect()
        for entry in entries { print("Launcher cache: \(entry.id), \(entry.status.rawValue), logical bytes=\(entry.bytes ?? -1)") }
        #expect(entries.filter { $0.id.hasSuffix("shared-pe-v2") }.allSatisfy { !$0.canClean })
    }

    @Test("A component revision creates coherent new Steam/game PE caches and preserves rollback caches")
    func componentCaches() async throws {
        let fixture = try ApplicationBundleFixture(); defer { fixture.remove() }
        let relative = "Contents/SharedSupport/wine/lib/wine/x86_64-windows/msctf.dll"
        try Data("original".utf8).write(to: fixture.layout.bundle.appendingPathComponent(relative))
        let old = try await SteamApplicationBundle(layout: fixture.layout).prepare()
        let updatedBundle = try ManagedDirectory.canonicalRoot(fixture.parent.appendingPathComponent("Updated.app"))
        try FileManager.default.copyItem(at: fixture.layout.bundle, to: updatedBundle)
        let bytes = Data("backport".utf8)
        try bytes.write(to: updatedBundle.appendingPathComponent(relative))
        var hashes = fixture.layout.profile.hashes
        hashes[relative] = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let profile = RuntimeProfile(identity: fixture.layout.profile.identity, bundlePath: "unused", wineVersionOutput: "fixture",
            hashes: hashes, revision: .textInput1)
        let layout = RuntimeLayout(dataRoot: fixture.layout.dataRoot, profile: profile, bundle: updatedBundle)
        let steam = try await SteamApplicationBundle(layout: layout).prepare()
        let game = try await SteamApplicationBundle(layout: layout, game: .init(appID: 553850, name: "Helldivers")).prepare()
        let suffix = "Contents/lib/wine/x86_64-windows/msctf.dll"
        #expect(steam != old)
        #expect(try Data(contentsOf: old.appendingPathComponent(suffix)) == Data("original".utf8))
        #expect(try Data(contentsOf: game.appendingPathComponent(suffix)) == bytes)
        let steamInfo = try FileManager.default.attributesOfItem(atPath: steam.appendingPathComponent(suffix).path)
        let gameInfo = try FileManager.default.attributesOfItem(atPath: game.appendingPathComponent(suffix).path)
        #expect(steamInfo[.systemFileNumber] as? NSNumber == gameInfo[.systemFileNumber] as? NSNumber)
        #expect(try await SteamApplicationBundle(layout: fixture.layout).prepare() == old)
    }

    @Test("Games receive distinct filesystem identities without changing Steam or runtime bytes")
    func gameIdentity() async throws {
        let fixture = try ApplicationBundleFixture(); defer { fixture.remove() }
        let steam = try await SteamApplicationBundle(layout: fixture.layout).prepare()
        let builder = SteamApplicationBundle(layout: fixture.layout, game: .init(appID: 526870, name: "Satisfactory"))
        let game = try await builder.prepare()
        #expect(game.lastPathComponent == "Satisfactory.app")
        #expect(game.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent == "526870")
        #expect(game != steam)
        #expect(try Data(contentsOf: builder.executable) == Data(contentsOf: fixture.layout.wine))
        #expect(try await builder.prepare() == game)
        try SteamApplicationBundle(layout: fixture.layout).validate(steam)
        #expect(try Data(contentsOf: fixture.layout.wine) == Data("wine fixture".utf8))
        let steamPE = steam.appendingPathComponent("Contents/lib/wine/x86_64-windows/ntdll.dll")
        let gamePE = game.appendingPathComponent("Contents/lib/wine/x86_64-windows/ntdll.dll")
        let sourceInfo = try FileManager.default.attributesOfItem(atPath: steamPE.path)
        let gameInfo = try FileManager.default.attributesOfItem(atPath: gamePE.path)
        #expect(sourceInfo[.systemFileNumber] as? NSNumber == gameInfo[.systemFileNumber] as? NSNumber)
        let bytes = try Data(contentsOf: steamPE)
        try FileManager.default.removeItem(at: gamePE)
        try bytes.write(to: gamePE)
        await #expect(throws: EnvironmentStoreError.identityMismatch) { try await builder.prepare() }
        #expect(try Data(contentsOf: steamPE) == bytes)
    }

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
