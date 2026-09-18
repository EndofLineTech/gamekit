import CryptoKit
import Foundation
import Testing
@testable import GamekitCore

enum DriverVersionExperiment {
    static func root() throws -> URL? {
        guard let path = ProcessInfo.processInfo.environment["GAMEKIT_DRIVER_EXPERIMENT"] else { return nil }
        try #require(path.hasPrefix("/"))
        let root = try ManagedDirectory.canonicalRoot(URL(fileURLWithPath: path))
        let production = try ManagedDirectory.canonicalRoot(EnvironmentStore.applicationSupportRoot)
        try #require(!root.path.hasPrefix(production.path) && !production.path.hasPrefix(root.path))
        return root
    }
    static func layout(root: URL, helper: URL? = nil) throws -> RuntimeLayout {
        if ProcessInfo.processInfo.environment["GAMEKIT_DRIVER_MANAGED_BUNDLE"] != nil {
            return RuntimeLayout(dataRoot: root.appendingPathComponent("Gamekit"), profile: .sikarugirDriverVersion1,
                bundle: root.appendingPathComponent("Runtime.app"), identityHelper: helper, graphicsBackend: .metal3)
        }
        let base = RuntimeProfile.sikarugirTextInput1
        var hashes = base.hashes
        let manifest = root.appendingPathComponent("trial-hashes.json")
        if FileManager.default.fileExists(atPath: manifest.path) {
            let extra = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: manifest))
            try #require(Set(extra.keys) == Set(["Contents/SharedSupport/wine/lib/wine/x86_64-windows/dxgi.dll",
                                                "Contents/SharedSupport/wine/lib/wine/x86_64-windows/dxgm.dll"]))
            hashes.merge(extra) { _, new in new }
        }
        let profile = RuntimeProfile(identity: base.identity, bundlePath: "Runtime.app",
            wineVersionOutput: base.wineVersionOutput, hashes: hashes)
        return RuntimeLayout(dataRoot: root.appendingPathComponent("Gamekit"), profile: profile,
            bundle: root.appendingPathComponent("Runtime.app"), identityHelper: helper, graphicsBackend: .metal3)
    }
}

@Suite("Opt-in isolated driver-version experiment")
struct DriverVersionExperimentTests {
    @Test("Stop only the isolated driver experiment", .enabled(if: ProcessInfo.processInfo.environment["GAMEKIT_STOP_DRIVER_EXPERIMENT"] == "1"))
    func stop() async throws {
        let root = try #require(try DriverVersionExperiment.root())
        let layout = try DriverVersionExperiment.layout(root: root)
        let lifecycle = SteamLifecycle(store: try EnvironmentStore(root: layout.dataRoot), layout: layout)
        print("Driver experiment stop: \(try await lifecycle.stop())")
        #expect(try await lifecycle.status() == .stopped)
    }
    @Test("Clone stopped runtime and prefix for driver-version trial",
          .enabled(if: ProcessInfo.processInfo.environment["GAMEKIT_PREPARE_DRIVER_EXPERIMENT"] == "1"))
    func prepare() async throws {
        let root = try #require(try DriverVersionExperiment.root())
        try #require(!FileManager.default.fileExists(atPath: root.path))
        let source = try EnvironmentStore()
        let sourceLayout = try await RuntimeSettingsStore(store: source).layout()
        try #require(sourceLayout.profile.revision == .textInput1 && sourceLayout.graphicsBackend == .metal3)
        let id = SteamInstallationRecipe.environmentID
        let record = try #require(await source.load(id))
        let installation = try await source.installationLease()
        let lease = try await source.executionLease(for: id)
        defer { withExtendedLifetime((installation, lease)) {} }
        let observed = await RuntimeProcessObserver().inspect(record: record, prefix: lease.prefix, layout: sourceLayout)
        try #require(observed.complete && observed.processes.isEmpty && record.installation == .installed)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let layout = try DriverVersionExperiment.layout(root: root)
        let store = try EnvironmentStore(root: layout.dataRoot)
        var cloned = record; cloned.revision = 0; cloned.name = "Driver version experiment"
        _ = try await store.create(cloned)
        let sourceBundle = ProcessInfo.processInfo.environment["GAMEKIT_DRIVER_MANAGED_BUNDLE"].map { URL(fileURLWithPath: $0) } ?? sourceLayout.bundle
        for (from, to) in [(sourceBundle, layout.bundle), (lease.prefix, store.prefixURL(for: id))] {
            try #require(!FileManager.default.fileExists(atPath: to.path))
            try FileManager.default.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
            let result = try await ProcessExecutor().run(.init(executable: URL(fileURLWithPath: "/bin/cp"),
                arguments: ["-cR", from.path, to.path], timeout: 240, outputLimit: 4096))
            try #require(result.termination == .exited(0), "APFS clone required: \(result.stderrText)")
        }
        let presentation = "Metadata/GamePresentation.json"
        try FileManager.default.copyItem(at: source.root.appendingPathComponent(presentation),
                                         to: store.root.appendingPathComponent(presentation))
        try lease.validate()
        let report = try await RuntimeDetector().detect(layout, selection: layout.profile.identity)
        try #require(report.prerequisites == .ready)
        print("Stopped prefix and accepted runtime cloned; primary selection unchanged")
    }

    @Test("Probe the actual DXGI version and D3D12 device in isolated runtime",
          .enabled(if: ProcessInfo.processInfo.environment["GAMEKIT_DRIVER_PROBE"] == "1"))
    func probe() async throws {
        let root = try #require(try DriverVersionExperiment.root())
        let layout = try DriverVersionExperiment.layout(root: root)
        let store = try EnvironmentStore(root: layout.dataRoot)
        let exe = try #require(ProcessInfo.processInfo.environment["GAMEKIT_DRIVER_PROBE_PATH"])
        let expected = ProcessInfo.processInfo.environment["GAMEKIT_DRIVER_EXPECT"] ?? "baseline"
        try #require(["baseline", "substituted", "configure", "contract"].contains(expected))
        let session = try await RuntimeSession.start(store: store, id: SteamInstallationRecipe.environmentID,
            layout: layout, arguments: [exe, expected], timeout: 60)
        let result = await session.command.result()
        print(result.stdoutText); print(result.stderrText)
        _ = try await session.stop()
        #expect(try await session.snapshot().processes.isEmpty)
        try #require(result.termination == .exited(0))
        let marker = expected == "configure" ? "Isolated per-app DXGI overrides configured"
            : expected == "contract" ? "Driver shim contract passed" : "D3D12CreateDevice hr=00000000"
        try #require(result.stdoutText.contains(marker))
    }
}
