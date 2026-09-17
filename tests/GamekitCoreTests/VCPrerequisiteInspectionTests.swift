import Foundation
import Testing
@testable import GamekitCore

@Suite("Opt-in VC prerequisite inspection")
struct VCPrerequisiteInspectionTests {
    @Test("Inspect installed VC libraries in the owned live session", .enabled(if: ProcessInfo.processInfo.environment["GAMEKIT_VC_PROBE"] == "1"))
    func inspect() async throws {
        let executable = try #require(ProcessInfo.processInfo.environment["GAMEKIT_VC_PROBE_PATH"])
        let store = try EnvironmentStore()
        let layout = try await RuntimeSettingsStore(store: store).layout()
        let lifecycle = SteamLifecycle(store: store, layout: layout)
        try #require(await lifecycle.status() == .running)
        let installation = try await store.installationLease()
        defer { withExtendedLifetime(installation) {} }
        let id = SteamInstallationRecipe.environmentID
        let record = try #require(await store.load(id))
        let lease = try await store.executionLease(for: id)
        defer { withExtendedLifetime(lease) {} }
        struct Receipt: Decodable { let token: UUID; let device: Int32; let inode: UInt64 }
        let root = try #require(try ManagedDirectory.openRoot(store.root, create: false))
        let bytes = try #require(try root.directory("Metadata")?.directory("Lifecycle")?.read("steam.json"))
        let receipt = try JSONDecoder().decode(Receipt.self, from: bytes)
        try #require(lease.prefixIdentity.device == receipt.device && lease.prefixIdentity.inode == receipt.inode)
        let snapshot = await RuntimeProcessObserver().inspect(record: record, prefix: lease.prefix, layout: layout)
        try #require(snapshot.complete && !snapshot.processes.isEmpty)
        try #require(snapshot.processes.allSatisfy { $0.sessionID == receipt.token.uuidString })
        for useManagedPolicy in [false, true] {
            try lease.validate()
            var environment = layout.environment(prefix: lease.prefix, session: receipt.token.uuidString)
            if !useManagedPolicy { environment.removeValue(forKey: "WINEDLLOVERRIDES") }
            let result = try await ProcessExecutor().run(.init(executable: layout.wine, arguments: [executable],
                environment: environment, workingDirectory: lease.prefix, timeout: 20, outputLimit: 16384))
            print("VC probe managed policy=\(useManagedPolicy): \(result.termination)")
            print(String(decoding: result.stdout, as: UTF8.self))
            if useManagedPolicy { #expect(result.termination == .exited(0)) }
            try lease.validate()
        }
    }
}
