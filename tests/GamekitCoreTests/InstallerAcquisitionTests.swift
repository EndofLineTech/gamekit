import CryptoKit
import Foundation
import Testing
@testable import GamekitCore

private func installerPE() -> Data {
    var bytes = [UInt8](repeating: 0, count: 1024)
    func word(_ offset: Int, _ value: Int, _ width: Int = 2) {
        for i in 0..<width { bytes[offset + i] = UInt8(truncatingIfNeeded: value >> (8 * i)) }
    }
    bytes[0] = 0x4d; bytes[1] = 0x5a
    word(0x3c, 128, 4)
    bytes[128] = 0x50; bytes[129] = 0x45
    word(132, 0x14c); word(134, 1); word(148, 224); word(150, 2)
    word(152, 0x10b); word(152 + 60, 512, 4)
    word(376 + 16, 512, 4); word(376 + 20, 512, 4)
    return Data(bytes)
}

private struct AcquisitionFixture {
    let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    var root: URL { parent.appendingPathComponent("Gamekit") }
    init() throws { try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true) }
    func remove() { try? FileManager.default.removeItem(at: parent) }
}

private actor WaitingTransfer {
    var started = false
    func fetch() async throws -> InstallerPayload {
        started = true
        try await Task.sleep(for: .seconds(30))
        return .fixture(installerPE())
    }
}

/// Exercises URLSession response/stream handling without depending on a network
/// server. Scenario selection belongs to each session, with no shared mutable state.
private final class InstallerProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let scenario = request.value(forHTTPHeaderField: "X-Installer-Fixture") ?? "valid"
        var headers = ["Content-Length": "1024"]
        if scenario == "unbounded" { headers.removeValue(forKey: "Content-Length") }
        if scenario == "oversize" { headers["Content-Length"] = String(InstallerSourcePolicy.maximumBytes + 1) }
        if scenario == "encoding" { headers["Content-Encoding"] = "gzip" }
        if scenario == "range" { headers["Content-Range"] = "bytes 0-1023/2048" }
        let response = HTTPURLResponse(url: InstallerSourcePolicy.source, statusCode: scenario == "status" ? 503 : 200,
                                       httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if scenario == "interrupted" {
            client?.urlProtocol(self, didLoad: Data(installerPE().prefix(512)))
            client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
        } else {
            client?.urlProtocol(self, didLoad: scenario == "short" ? Data(installerPE().prefix(512)) : installerPE())
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {}
}

@Suite("Steam installer acquisition")
struct InstallerAcquisitionTests {
    @Test("Official URL policy rejects credential-bearing, downgrade and lookalike redirects")
    func sourcePolicy() throws {
        #expect(InstallerSourcePolicy.allows(InstallerSourcePolicy.source))
        for url in ["http://cdn.fastly.steamstatic.com/client/installer/SteamSetup.exe",
                    "https://cdn.fastly.steamstatic.com.evil.test/client/installer/SteamSetup.exe",
                    "https://user:password@cdn.fastly.steamstatic.com/client/installer/SteamSetup.exe",
                    "https://cdn.fastly.steamstatic.com:444/client/installer/SteamSetup.exe",
                    "https://cdn.fastly.steamstatic.com/client/installer/SteamSetup.exe?token=private",
                    "https://cdn.fastly.steamstatic.com/client/installer/steam.dmg"] {
            #expect(!InstallerSourcePolicy.allows(try #require(URL(string: url))))
        }
        let redirects = InstallerRedirectPolicy()
        for _ in 0..<5 { #expect(redirects.accept(InstallerSourcePolicy.source)) }
        #expect(!redirects.accept(InstallerSourcePolicy.source))
    }

    @Test("Redirect delegate follows only approved destinations and strips incoming headers")
    func redirectDelegate() async throws {
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: InstallerSourcePolicy.source)
        let response = try #require(HTTPURLResponse(url: InstallerSourcePolicy.source, statusCode: 302, httpVersion: nil, headerFields: nil))
        for url in [InstallerSourcePolicy.source, URL(string: "https://example.com/SteamSetup.exe")!] {
            var request = URLRequest(url: url)
            request.setValue("private", forHTTPHeaderField: "Authorization")
            let result: URLRequest? = await withCheckedContinuation { continuation in
                InstallerRedirectPolicy().urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: request) {
                    continuation.resume(returning: $0)
                }
            }
            if url == InstallerSourcePolicy.source {
                #expect(result?.url == url)
                #expect(result?.value(forHTTPHeaderField: "Authorization") == nil)
            } else { #expect(result == nil) }
        }
    }

    @Test("Malformed PE offsets, architectures, DLLs and certificate bounds are rejected")
    func executableStructure() throws {
        for (offset, value) in [(0x3c, UInt8(0xff)), (132, 0), (151, 0x20), (376 + 21, 0xff)] {
            var data = installerPE(); data[offset] = value
            #expect(throws: InstallerAcquisitionError.invalidExecutable) { try InstallerExecutable.validate(data) }
        }
        var signed = installerPE()
        signed[152 + 92] = 5
        signed[152 + 96 + 32] = 0xff
        signed[152 + 96 + 32 + 4] = 8
        #expect(throws: InstallerAcquisitionError.invalidExecutable) { try InstallerExecutable.validate(signed) }
    }

    @Test("Only a complete PE is published with provenance and revalidated after reopening")
    func acquisition() async throws {
        let fixture = try AcquisitionFixture(); defer { fixture.remove() }
        let data = installerPE()
        let store = try SteamInstallerAcquisition(root: fixture.root, transfer: { InstallerPayload.fixture(data) })
        let artifact = try await store.acquire()
        #expect(artifact.provenance.source == InstallerSourcePolicy.source)
        #expect(artifact.provenance.sha256 == SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
        let reopened = try SteamInstallerAcquisition(root: fixture.root)
        let loaded = try await reopened.load(artifact.id)
        let url = try await reopened.validatedURL(for: loaded)
        #expect(try Data(contentsOf: url) == data)
        try Data("tampered".utf8).write(to: url)
        await #expect(throws: (any Error).self) { try await reopened.validatedURL(for: loaded) }
    }

    @Test("HTML, truncated PE and invalid HTTP responses never publish an installer")
    func invalidDownloads() async throws {
        let fixture = try AcquisitionFixture(); defer { fixture.remove() }
        var cases = [InstallerPayload.fixture(Data("<html>error</html>".utf8)),
                     InstallerPayload.fixture(Data(installerPE().prefix(600)))]
        cases.append(InstallerPayload(data: installerPE(), finalURL: InstallerSourcePolicy.source, status: 206, expectedBytes: 1024))
        cases.append(InstallerPayload(data: installerPE(), finalURL: InstallerSourcePolicy.source, status: 200, expectedBytes: 2048))
        for payload in cases {
            let store = try SteamInstallerAcquisition(root: fixture.root, transfer: { payload })
            await #expect(throws: (any Error).self) { try await store.acquire() }
        }
        let names = try FileManager.default.contentsOfDirectory(atPath: fixture.root.appendingPathComponent("InstallerDownloads").path)
        #expect(!names.contains { $0.hasSuffix(".exe") || $0.hasSuffix(".json") })
    }

    @Test("Interrupted transfers can be retried without publishing partial bytes")
    func interrupted() async throws {
        let fixture = try AcquisitionFixture(); defer { fixture.remove() }
        let failed = try SteamInstallerAcquisition(root: fixture.root, transfer: { throw URLError(.networkConnectionLost) })
        await #expect(throws: (any Error).self) { try await failed.acquire() }
        let retry = try SteamInstallerAcquisition(root: fixture.root, transfer: { .fixture(installerPE()) })
        let artifact = try await retry.acquire()
        #expect(try await retry.validatedURL(for: artifact).pathExtension == "exe")
    }

    @Test("Cancellation releases acquisition ownership and publishes no installer")
    func cancellation() async throws {
        let fixture = try AcquisitionFixture(); defer { fixture.remove() }
        let waiting = WaitingTransfer()
        let store = try SteamInstallerAcquisition(root: fixture.root, transfer: { try await waiting.fetch() })
        let task = Task { try await store.acquire() }
        while !(await waiting.started) { try await Task.sleep(for: .milliseconds(1)) }
        await #expect(throws: EnvironmentStoreError.busy) { try await store.acquire() }
        let other = try SteamInstallerAcquisition(root: fixture.root, transfer: { .fixture(installerPE()) })
        await #expect(throws: EnvironmentStoreError.busy) { try await other.acquire() }
        task.cancel()
        await #expect(throws: (any Error).self) { try await task.value }
        let names = try FileManager.default.contentsOfDirectory(atPath: fixture.root.appendingPathComponent("InstallerDownloads").path)
        #expect(!names.contains { $0.hasSuffix(".exe") || $0.hasSuffix(".json") })
        let retry = try SteamInstallerAcquisition(root: fixture.root, transfer: { .fixture(installerPE()) })
        _ = try await retry.acquire()
    }

    @Test("Actual URLSession stream rejects errors, partial data and invalid responses", arguments: ["valid", "interrupted", "short", "status", "oversize", "encoding", "range"])
    func httpStream(scenario: String) async throws {
        let fixture = try AcquisitionFixture(); defer { fixture.remove() }
        let store = try SteamInstallerAcquisition(root: fixture.root, transfer: {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [InstallerProtocol.self]
            configuration.httpAdditionalHeaders = ["X-Installer-Fixture": scenario]
            return try await InstallerHTTPClient.fetch(configuration: configuration)
        })
        if scenario == "valid" {
            let artifact = try await store.acquire()
            #expect(artifact.byteCount == 1024)
        } else {
            await #expect(throws: (any Error).self) { try await store.acquire() }
            let names = try FileManager.default.contentsOfDirectory(atPath: fixture.root.appendingPathComponent("InstallerDownloads").path)
            #expect(!names.contains { $0.hasSuffix(".exe") || $0.hasSuffix(".json") })
        }
    }

    @Test("A stream without Content-Length is bounded while being received")
    func streamingLimit() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [InstallerProtocol.self]
        configuration.httpAdditionalHeaders = ["X-Installer-Fixture": "unbounded"]
        await #expect(throws: InstallerAcquisitionError.tooLarge) {
            try await InstallerHTTPClient.fetch(configuration: configuration, byteLimit: 512)
        }
    }

    @Test("Replacing the artifact directory during a download refuses publication")
    func changedDirectory() async throws {
        let fixture = try AcquisitionFixture(); defer { fixture.remove() }
        let directory = fixture.root.appendingPathComponent("InstallerDownloads")
        let displaced = fixture.parent.appendingPathComponent("displaced")
        let store = try SteamInstallerAcquisition(root: fixture.root, transfer: {
            try FileManager.default.moveItem(at: directory, to: displaced)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            return .fixture(installerPE())
        })
        await #expect(throws: EnvironmentStoreError.identityMismatch) { try await store.acquire() }
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: displaced.path) == [".acquisition.lock"])
    }

    @Test("Receiptless files and symlinked artifacts cannot be loaded")
    func storedArtifactSafety() async throws {
        let fixture = try AcquisitionFixture(); defer { fixture.remove() }
        let store = try SteamInstallerAcquisition(root: fixture.root, transfer: { .fixture(installerPE()) })
        let artifact = try await store.acquire()
        let url = try await store.validatedURL(for: artifact)
        let external = fixture.parent.appendingPathComponent("external.exe")
        try installerPE().write(to: external)
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: external)
        await #expect(throws: EnvironmentStoreError.unsafePath) { try await store.load(artifact.id) }
        let receipt = url.deletingPathExtension().appendingPathExtension("json")
        try FileManager.default.removeItem(at: receipt)
        await #expect(throws: EnvironmentStoreError.notFound) { try await store.load(artifact.id) }
        #expect(try Data(contentsOf: external) == installerPE())
    }

    @Test("Abandoned acquisition temporaries are reclaimed without touching unrelated artifacts")
    func recoveryCleanup() async throws {
        let fixture = try AcquisitionFixture(); defer { fixture.remove() }
        let directory = fixture.root.appendingPathComponent("InstallerDownloads")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let orphan = directory.appendingPathComponent(".installer-\(UUID().uuidString).tmp")
        let unknown = directory.appendingPathComponent("manual.exe")
        try Data("partial".utf8).write(to: orphan)
        try Data("preserve".utf8).write(to: unknown)
        let store = try SteamInstallerAcquisition(root: fixture.root, transfer: { .fixture(installerPE()) })
        _ = try await store.acquire()
        #expect(!FileManager.default.fileExists(atPath: orphan.path))
        #expect(try Data(contentsOf: unknown) == Data("preserve".utf8))
    }

    @Test("Real official HTTPS download validates and reopens without executing", .enabled(if: ProcessInfo.processInfo.environment["GAMEKIT_INSTALLER_SMOKE"] == "1"))
    func officialInstaller() async throws {
        let fixture = try AcquisitionFixture(); defer { fixture.remove() }
        let store = try SteamInstallerAcquisition(root: fixture.root)
        let artifact = try await store.acquire()
        #expect(artifact.byteCount > 1024)
        _ = try await store.validatedURL(for: artifact)
        print("Installer smoke: bytes=\(artifact.byteCount) sha256=\(artifact.provenance.sha256) source=\(artifact.finalURL.absoluteString)")
    }
}

private extension InstallerPayload {
    static func fixture(_ data: Data) -> Self {
        .init(data: data, finalURL: InstallerSourcePolicy.source, status: 200, expectedBytes: Int64(data.count))
    }
}
