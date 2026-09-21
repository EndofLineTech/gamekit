import Foundation
import Testing
@testable import GamekitCore

/// Operator-only E6 control. Steam presents the install dialog; this does not
/// approve downloads, accept licenses or use the native macOS Steam handler.
@Suite("Opt-in E6 install dialog")
struct GameEvaluationControlTests {
    @Test("Open the Windows Steam install dialog for an approved title",
          .enabled(if: ProcessInfo.processInfo.environment["GAMEKIT_E6_SHOW_INSTALL"] == "1"))
    func showInstall() async throws {
        let rawID = try #require(ProcessInfo.processInfo.environment["GAMEKIT_E6_APPID"])
        let appID = try #require(UInt32(rawID))
        try #require([GameFixtures.primary.appId, GameFixtures.other.appId].contains(appID))
        let store = try EnvironmentStore()
        let layout = try await RuntimeSettingsStore(store: store).layout()
        let lifecycle = SteamLifecycle(store: store, layout: layout)
        _ = try await lifecycle.launch()
        try await lifecycle.show()
        let installation = try await store.installationLease()
        defer { withExtendedLifetime(installation) {} }
        let id = SteamInstallationRecipe.environmentID
        let record = try #require(await store.load(id))
        let lease = try await store.executionLease(for: id)
        defer { withExtendedLifetime(lease) {} }
        struct Receipt: Decodable { let token: UUID; let device: Int32; let inode: UInt64 }
        let root = try #require(try ManagedDirectory.openRoot(store.root, create: false))
        let data = try #require(try root.directory("Metadata")?.directory("Lifecycle")?.read("steam.json"))
        let receipt = try JSONDecoder().decode(Receipt.self, from: data)
        try #require(receipt.device == lease.prefixIdentity.device && receipt.inode == lease.prefixIdentity.inode)
        let observed = await RuntimeProcessObserver().inspect(record: record, prefix: lease.prefix, layout: layout)
        try #require(observed.complete && !observed.processes.isEmpty && observed.processes.allSatisfy { $0.sessionID == receipt.token.uuidString })
        try lease.validate()
        let steam = lease.prefix.appendingPathComponent(record.steamExecutable.rawValue)
        let result = try await ProcessExecutor().run(.init(executable: layout.wine,
            arguments: [steam.path, "steam://install/\(appID)"],
            environment: layout.environment(prefix: lease.prefix, session: receipt.token.uuidString),
            workingDirectory: steam.deletingLastPathComponent(), timeout: 10, outputLimit: 4096))
        try lease.validate()
        #expect(result.termination == .exited(0))
        print("Windows Steam install dialog requested for AppID \(appID); download confirmation remains pending.")
    }
}
