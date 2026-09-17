import CryptoKit
import Foundation
import Testing
@testable import GamekitCore

enum HelldiversTextInputExperiment {
    static let dllRelative = "Contents/SharedSupport/wine/lib/wine/x86_64-windows/msctf.dll"
    static var control: Bool { ProcessInfo.processInfo.environment["GAMEKIT_TEXT_INPUT_CONTROL"] == "1" }
    static var dllHash: String {
        control ? "879f013ac17231de312e04c0db6b4f6dcbc4ee77d0bc439099b6dbe92286f9ae"
            : "bb8db266526cff89c2bc6a436482b24c632c13596c1864adb4cb2e42e58fca8b"
    }

    static func root() throws -> URL? {
        guard let path = ProcessInfo.processInfo.environment["GAMEKIT_TEXT_INPUT_EXPERIMENT"] else { return nil }
        try #require(path.hasPrefix("/"))
        let root = try ManagedDirectory.canonicalRoot(URL(fileURLWithPath: path))
        let production = try ManagedDirectory.canonicalRoot(EnvironmentStore.applicationSupportRoot)
        try #require(!root.path.hasPrefix(production.path) && !production.path.hasPrefix(root.path))
        return root
    }

    static func layout(root: URL, helper: URL? = nil) -> RuntimeLayout {
        var hashes = RuntimeProfile.sikarugir.hashes
        hashes[dllRelative] = dllHash
        let profile = RuntimeProfile(identity: RuntimeIdentity(provider: "Gamekit experiment",
            distribution: control ? "wine10-msctf-control" : "wine10-msctf-backport-1", wine: "10.0", graphics: "4.0b2"),
            bundlePath: "Runtime.app", wineVersionOutput: RuntimeProfile.sikarugir.wineVersionOutput, hashes: hashes)
        return RuntimeLayout(dataRoot: root.appendingPathComponent("Gamekit"), profile: profile,
            bundle: root.appendingPathComponent("Runtime.app"), identityHelper: helper)
    }

    static func hash(_ url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }
}

@Suite("Opt-in isolated Helldivers text-input experiment")
struct HelldiversTextInputExperimentTests {
    @Test("Explicit cleanup of the isolated experimental session",
          .enabled(if: ProcessInfo.processInfo.environment["GAMEKIT_STOP_TEXT_INPUT_EXPERIMENT"] == "1"))
    func stop() async throws {
        let root = try #require(try HelldiversTextInputExperiment.root())
        let layout = HelldiversTextInputExperiment.layout(root: root)
        let store = try EnvironmentStore(root: layout.dataRoot)
        let lifecycle = SteamLifecycle(store: store, layout: layout)
        print("Experimental session cleanup: \(try await lifecycle.stop())")
        #expect(try await lifecycle.status() == .stopped)
    }

    @Test("Clone the stopped environment and runtime before installing the experimental DLL",
          .enabled(if: ProcessInfo.processInfo.environment["GAMEKIT_PREPARE_TEXT_INPUT_EXPERIMENT"] == "1"))
    func prepare() async throws {
        let root = try #require(try HelldiversTextInputExperiment.root())
        let candidate = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["GAMEKIT_TEXT_INPUT_DLL"]))
        try #require(try HelldiversTextInputExperiment.hash(candidate) == HelldiversTextInputExperiment.dllHash)
        try #require(!FileManager.default.fileExists(atPath: root.path))
        let sourceStore = try EnvironmentStore()
        let sourceLayout = try await RuntimeSettingsStore(store: sourceStore).layout()
        let id = SteamInstallationRecipe.environmentID
        let record = try #require(await sourceStore.load(id))
        let installation = try await sourceStore.installationLease()
        let lease = try await sourceStore.executionLease(for: id)
        defer { withExtendedLifetime((installation, lease)) {} }
        let snapshot = await RuntimeProcessObserver().inspect(record: record, prefix: lease.prefix, layout: sourceLayout)
        try #require(snapshot.complete && snapshot.processes.isEmpty)
        try #require(record.installation == .installed)
        let sourceDLL = sourceLayout.bundle.appendingPathComponent(HelldiversTextInputExperiment.dllRelative)
        let sourceHash = try HelldiversTextInputExperiment.hash(sourceDLL)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        let layout = HelldiversTextInputExperiment.layout(root: root)
        let store = try EnvironmentStore(root: layout.dataRoot)
        var clonedRecord = record
        clonedRecord.revision = 0
        clonedRecord.runtime = layout.profile.identity
        clonedRecord.name = "Helldivers text-input experiment"
        _ = try await store.create(clonedRecord)
        for (source, destination) in [(sourceLayout.bundle, layout.bundle), (lease.prefix, store.prefixURL(for: id))] {
            try #require(!FileManager.default.fileExists(atPath: destination.path))
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            let result = try await ProcessExecutor().run(.init(executable: URL(fileURLWithPath: "/bin/cp"),
                arguments: ["-cR", source.path, destination.path], timeout: 240, outputLimit: 4096))
            if result.termination != .exited(0) { print(result.stderrText) }
            try #require(result.termination == .exited(0), "APFS clone must succeed; no ordinary-copy fallback")
        }
        for destination in [layout.bundle.appendingPathComponent(HelldiversTextInputExperiment.dllRelative),
                            store.prefixURL(for: id).appendingPathComponent("drive_c/windows/system32/msctf.dll")] {
            // Unlink the cloned entry first, including a possible Wine symlink.
            try FileManager.default.removeItem(at: destination)
            try FileManager.default.copyItem(at: candidate, to: destination)
            try #require(try HelldiversTextInputExperiment.hash(destination) == HelldiversTextInputExperiment.dllHash)
        }
        try lease.validate()
        try #require(try HelldiversTextInputExperiment.hash(sourceDLL) == sourceHash)
        let report = try await RuntimeDetector().detect(layout, selection: layout.profile.identity)
        try #require(report.prerequisites == .ready)
        print("Isolated runtime and prefix prepared; original runtime DLL hash unchanged")
    }
}
