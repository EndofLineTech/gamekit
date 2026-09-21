import Foundation
import Testing
import Synchronization
@testable import GamekitCore

@Suite("Downloadable game profiles")
struct GameProfileTests {
    @Test("Execution profiles reject registry injection, unqualified adapters and unknown actions")
    func invalidExecution() throws {
        let source = try #require(GameProfileStore.bundled(appID: 553850))
        let original = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(source)) as? [String: Any])
        for invalid in ["../fixture.exe", "fixture.exe\\Mac Driver", "fixture.exe\nInjected=1"] {
            var document = original
            var execution = try #require(document["execution"] as? [String: Any])
            execution["executable"] = invalid; document["execution"] = execution
            #expect(throws: (any Error).self) { try GameProfile.decode(JSONSerialization.data(withJSONObject: document), appID: 553850) }
        }
        for (key, value): (String, Any) in [("runtimeRevisions", ["original"]), ("backends", ["dxvk"]),
                                          ("replacementVersion", [65536, 0, 0, 0]), ("script", "run") ] {
            var document = original
            var execution = try #require(document["execution"] as? [String: Any])
            var driver = try #require(execution["driver"] as? [String: Any])
            driver[key] = value; execution["driver"] = driver; document["execution"] = execution
            #expect(throws: (any Error).self) { try GameProfile.decode(JSONSerialization.data(withJSONObject: document), appID: 553850) }
        }
    }

    @Test("Execution capabilities belong to profiles, not known AppIDs")
    func executionIsDataDriven() async throws {
        let source = try #require(GameProfileStore.bundled(appID: 553850))
        var document = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(source)) as? [String: Any])
        document["appId"] = 42
        document["revision"] = 99
        document["name"] = "Unrecognized fixture game"
        var execution = try #require(document["execution"] as? [String: Any])
        execution["executable"] = "fixture.exe"
        document["execution"] = execution
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        try await GameProfileStore(root: root).accept(JSONSerialization.data(withJSONObject: document), appID: 42)
        #expect(GameCompatibilityStore.supports(42, root: root))
        #expect(GameCompatibilityPreferences().driverEnabled(appID: 42, revision: .driverVersion1, root: root))
        let profile = try #require(GameProfileStore.resolved(appID: 42, root: root)?.profile)
        #expect(profile.execution.executable == "fixture.exe")
        let registry = try GameCaptureRegistry(Data("WINE REGISTRY Version 2\n".utf8), executable: "fixture.exe")
        let captured = try #require(String(data: registry.setting(.enabled), encoding: .utf8))
        #expect(captured.contains("fixture.exe"))
        #expect(!captured.contains(GameFixtures.primary.executable))
        let metadataRoot = try ManagedDirectory.canonicalRoot(root)
        let layout = RuntimeLayout(dataRoot: metadataRoot, profile: .sikarugirDriverVersion1, graphicsBackend: .metal3)
        #expect(try SteamApplicationBundle.configured(layout: layout, game: .init(appID: 42, name: "Fixture")).driverCompatibility)
        let prefix = metadataRoot.appendingPathComponent("Environments/steam")
        try GameDockNames.publish(root: metadataRoot, prefix: prefix, session: UUID(),
            games: [.init(id: 42, name: "Fixture", installDirectory: "Fixture", buildID: nil, state: .ready, artwork: nil)],
            graphicsBackend: .metal3, libraryLayout: layout, validate: {})
        let projection = try Data(contentsOf: metadataRoot.appendingPathComponent("Metadata/GameDock/steam-drivers.ini"))
        let ini = try #require(String(data: projection, encoding: .utf16))
        #expect(ini.contains("Executable=fixture.exe") && ini.contains("Replacement=" + GameFixtures.primary.replacementHex))
        let mapping = try JSONDecoder().decode(GameDockNames.self, from: Data(contentsOf: GameDockNames.url(root: metadataRoot, prefix: prefix)))
        #expect(mapping.fullscreenExecutables?["42"] == "fixture.exe")
        try GameDockNames.publish(root: metadataRoot, prefix: prefix, session: UUID(), games: [], libraryLayout: layout, validate: {})
        #expect(try Data(contentsOf: metadataRoot.appendingPathComponent("Metadata/GameDock/steam-drivers.ini")).count == 2)
    }
    @Test("Published profiles round-trip through the production HTTPS client",
          .enabled(if: ProcessInfo.processInfo.environment["GAMEKIT_VERIFY_PUBLISHED_PROFILES"] == "1"))
    func publishedProfiles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = GameProfileStore(root: root)
        for id: UInt32 in [15100, 526870, 553850] {
            try await store.refresh(appID: id)
            let resolved = try #require(GameProfileStore.resolved(appID: id, root: root))
            #expect(resolved.source == "Downloaded from compatibility wiki")
            #expect(resolved.profile.appId == id)
        }
    }

    private func data(id: UInt32 = GameFixtures.renderer.appId, revision: Int = 3,
                      arguments: [String] = [GameFixtures.renderer.option("dx11")]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "revision": revision,
            "appId": id, "name": "Satisfactory", "runtime": "sikarugir-10.0_6",
            "launchArguments": ["dxmt": arguments], "notes": "Test profile"])
    }

    @Test func bundledRulesPreserveExistingBehavior() throws {
        let profile = try #require(GameProfileStore.bundled(appID: 526870))
        #expect(profile.arguments(for: .dxmt).count == 2)
        #expect(profile.arguments(for: .dxvk) == GameFixtures.renderer.launchArguments?["dxvk"])
        #expect(profile.arguments(for: .metal3).isEmpty)
        #expect(GameProfileStore.bundled(appID: 42) == nil)
    }

    @Test func rejectsWrongIdentitySchemaAndCommands() throws {
        #expect(throws: (any Error).self) { try GameProfile.decode(data(), appID: 42) }
        for argument in ["%command%", "-dx11;touch /tmp/file", "-foo\n-bar", "-dx11\n", ""] {
            #expect(throws: (any Error).self) { try GameProfile.decode(data(arguments: [argument]), appID: 526870) }
        }
        var object = try #require(JSONSerialization.jsonObject(with: data()) as? [String: Any])
        object["schemaVersion"] = 2
        #expect(throws: (any Error).self) { try GameProfile.decode(JSONSerialization.data(withJSONObject: object), appID: 526870) }
        object["schemaVersion"] = 1; object["script"] = "echo unsafe"
        #expect(throws: (any Error).self) { try GameProfile.decode(JSONSerialization.data(withJSONObject: object), appID: 526870) }
    }

    @Test func cacheKeepsLastGoodAndRejectsRollback() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let canonical = try ManagedDirectory.canonicalRoot(root)
        let store = GameProfileStore(root: canonical)
        try await store.accept(data(), appID: 526870)
        #expect(GameProfileStore.resolved(appID: 526870, root: canonical)?.profile.revision == 3)
        await #expect(throws: (any Error).self) { try await store.accept(data(revision: 1), appID: 526870) }
        await #expect(throws: (any Error).self) { try await store.accept(Data("<html>error</html>".utf8), appID: 526870) }
        #expect(GameProfileStore.resolved(appID: 526870, root: canonical)?.profile.revision == 3)
        #expect(GraphicsBackend.dxmt.launchOptions(appID: GameFixtures.renderer.appId, root: canonical) == [GameFixtures.renderer.option("dx11")])
        #expect(GraphicsBackend.automatic.launchOptions(appID: 526870, root: canonical).isEmpty)
    }

    @Test func downloadsAndFailuresPreserveOfflineBehavior() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ProfileHTTPFixture.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let store = GameProfileStore(root: root, session: session)
        try await store.refresh(appID: 31)
        #expect(GameProfileStore.resolved(appID: 31, root: root)?.profile.arguments(for: .dxmt) == [GameFixtures.renderer.option("dx11")])
        let before = ProfileHTTPFixture.requests.withLock { $0 }
        try await store.refresh(appID: 31)
        #expect(ProfileHTTPFixture.requests.withLock { $0 } == before)
        try await store.refresh(appID: 32) // 404 means unknown; no negative profile replaces defaults.
        #expect(GameProfileStore.resolved(appID: 32, root: root) == nil)
        for id: UInt32 in [33, 34, 35, 36, 37] {
            await #expect(throws: (any Error).self) { try await store.refresh(appID: id) }
            #expect(GameProfileStore.resolved(appID: id, root: root) == nil)
        }
        let offlineConfig = URLSessionConfiguration.ephemeral
        offlineConfig.protocolClasses = [OfflineProfileHTTPFixture.self]
        let offlineSession = URLSession(configuration: offlineConfig)
        defer { offlineSession.invalidateAndCancel() }
        await #expect(throws: (any Error).self) {
            try await GameProfileStore(root: root, session: offlineSession).refresh(appID: 31)
        }
        #expect(GameProfileStore.resolved(appID: 31, root: root)?.profile.arguments(for: .dxmt) == [GameFixtures.renderer.option("dx11")])
    }

    @Test func corruptCacheFallsBackAndSymlinkCacheIsNotWritten() async throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let root = parent.appendingPathComponent("root")
        let outside = parent.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Metadata"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("Metadata/GameProfiles"), withDestinationURL: outside)
        await #expect(throws: (any Error).self) { try await GameProfileStore(root: root).accept(data(), appID: 526870) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
        #expect(GameProfileStore.resolved(appID: 526870, root: root)?.source == "Bundled offline profile")
        try FileManager.default.removeItem(at: root.appendingPathComponent("Metadata/GameProfiles"))
        try await GameProfileStore(root: root).accept(data(), appID: 526870)
        try Data("broken".utf8).write(to: root.appendingPathComponent("Metadata/GameProfiles/526870.json"))
        #expect(GameProfileStore.resolved(appID: 526870, root: root)?.profile.revision == 2)
    }
}

private final class ProfileHTTPFixture: URLProtocol, @unchecked Sendable {
    static let requests = Mutex(0)
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests.withLock { $0 += 1 }
        let id = UInt32(request.url!.deletingPathExtension().lastPathComponent)!
        if id == 37 { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)); return }
        let status = id == 32 ? 404 : id == 36 ? 500 : 200
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": id == 33 ? "text/html" : "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let data = id == 35 ? Data(repeating: 32, count: 32769) : Data("""
        {"schemaVersion":1,"revision":1,"appId":\(id == 34 ? 99 : id),"name":"Fixture","runtime":"sikarugir-10.0_6","launchArguments":{"dxmt":["\(GameFixtures.renderer.option("dx11"))"]},"notes":"Fixture"}
        """.utf8)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private final class OfflineProfileHTTPFixture: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)) }
    override func stopLoading() {}
}
