import Foundation
import Testing
@testable import GamekitCore

@Suite("Opt-in VC prerequisite inspection")
struct VCPrerequisiteInspectionTests {
    @Test("Compare system image addresses across managed loader identities", .enabled(if: ProcessInfo.processInfo.environment["GAMEKIT_WINE_IMAGE_COMPARISON"] == "1"))
    func compareImages() async throws {
        let executable = try #require(ProcessInfo.processInfo.environment["GAMEKIT_VC_PROBE_PATH"])
        let store = try EnvironmentStore()
        let layout = try await RuntimeSettingsStore(store: store).layout()
        let lifecycle = SteamLifecycle(store: store, layout: layout)
        _ = try await lifecycle.launch()
        do {
            struct Receipt: Decodable { let token: UUID }
            let bytes = try Data(contentsOf: store.root.appendingPathComponent("Metadata/Lifecycle/steam.json"))
            let receipt = try JSONDecoder().decode(Receipt.self, from: bytes)
            let lease = try await store.executionLease(for: SteamInstallationRecipe.environmentID)
            defer { withExtendedLifetime(lease) {} }
            let game = SteamApplicationBundle(layout: layout, game: .init(appID: 526870, name: "Satisfactory"))
            _ = try await game.prepare()
            var images: [String: String] = [:]
            for (name, loader) in [("source", layout.wine), ("Steam", SteamApplicationBundle(layout: layout).executable), ("game", game.executable)] {
                let result = try await ProcessExecutor().run(.init(executable: loader, arguments: [executable],
                    environment: layout.environment(prefix: lease.prefix, session: receipt.token.uuidString),
                    workingDirectory: lease.prefix, timeout: 15, outputLimit: 8192))
                images[name] = result.stdoutText.components(separatedBy: .newlines).filter { $0.hasPrefix("System image") }.joined()
                print(name + ": " + (images[name] ?? "missing"))
                #expect(result.termination == .exited(0))
            }
            #expect(images["Steam"]?.isEmpty == false && images["Steam"] == images["game"], "Steam remote-thread entry points must resolve to the same PE image addresses")
        } catch { _ = try? await lifecycle.stop(); throw error }
        _ = try await lifecycle.stop()
    }

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
