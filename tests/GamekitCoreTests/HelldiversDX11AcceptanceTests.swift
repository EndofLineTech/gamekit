import Foundation
import Testing
@testable import GamekitCore

@Suite("Opt-in Helldivers DX11 backend validation")
struct HelldiversDX11AcceptanceTests {
    @Test("Bounded DX11 launch restores backend and game settings on success or failure",
          .enabled(if: ProcessInfo.processInfo.environment["GAMEKIT_HELLDIVERS_DX11_BACKEND"] != nil))
    func observe() async throws {
        let env = ProcessInfo.processInfo.environment
        let choice = try #require(env["GAMEKIT_HELLDIVERS_DX11_BACKEND"].flatMap(GameGraphicsOverride.init(rawValue:)))
        try #require([.dxmt, .dxvk, .metal3].contains(choice))
        try #require(env["GAMEKIT_E6_HELLDIVERS_D3D11"] == "1" && env["GAMEKIT_E6_APPID"] == "553850")
        let settingsURL = URL(fileURLWithPath: try #require(env["GAMEKIT_E6_WARNING_SETTINGS"]))
        let store = try EnvironmentStore()
        let layout = try await RuntimeSettingsStore(store: store).layout()
        let lifecycle = SteamLifecycle(store: store, layout: layout)
        let record = try #require(await store.load(SteamInstallationRecipe.environmentID))
        let prefix = store.prefixURL(for: record.id)
        try #require(settingsURL.path.hasPrefix(prefix.path + "/drive_c/users/") && settingsURL.lastPathComponent == "user_settings.config")
        let snapshot = await RuntimeProcessObserver().inspect(record: record, prefix: prefix, layout: layout)
        try #require(snapshot.complete && !snapshot.processes.contains { $0.role == .other }, "Close games before validation")
        _ = try await lifecycle.stop()
        let preferences = GameCompatibilityStore(store: store)
        let original = try await preferences.inspectGraphics(appID: 553850)
        let directory = try #require(try ManagedDirectory.openRoot(settingsURL.deletingLastPathComponent(), create: false))
        let settings = try #require(try directory.read(settingsURL.lastPathComponent))
        let freshCache = env["GAMEKIT_HD_DX11_FRESH_CACHE"] == "1"
        let cacheBackup = ".gamekit-dx11-original-" + UUID().uuidString.lowercased()
        let cacheTrial = ".gamekit-dx11-trial-" + UUID().uuidString.lowercased()
        var originalCache: (device: Int32, inode: UInt64)?
        var trialCache: (device: Int32, inode: UInt64)?
        var trialArchived = false
        func isolateCache() async throws {
            guard freshCache else { return }
            let installation = try await store.installationLease()
            let lease = try await store.executionLease(for: record.id)
            defer { withExtendedLifetime((installation, lease)) {} }
            try lease.validate()
            let idle = await RuntimeProcessObserver().inspect(record: record, prefix: prefix, layout: layout)
            try #require(idle.complete && idle.processes.isEmpty)
            if let cache = try directory.directory("shader_cache") {
                let identity = try cache.identity()
                try directory.moveDirectory("shader_cache", to: directory, as: cacheBackup)
                originalCache = identity
            }
            trialCache = try directory.createExclusiveDirectory("shader_cache").identity()
        }
        func restore() async throws {
            _ = try await lifecycle.stop()
            let installation = try await store.installationLease()
            let lease = try await store.executionLease(for: record.id)
            let current = await RuntimeProcessObserver().inspect(record: record, prefix: prefix, layout: layout)
            try #require(current.complete && current.processes.isEmpty)
            try lease.validate()
            if let trialCache, !trialArchived {
                let cache = try #require(try directory.directory("shader_cache"))
                try #require(try cache.identity() == trialCache)
                try directory.moveDirectory("shader_cache", to: directory, as: cacheTrial)
                trialArchived = true
            }
            if let originalCache {
                let original = try #require(try directory.directory(cacheBackup))
                try #require(try original.identity() == originalCache)
                try directory.moveDirectory(cacheBackup, to: directory, as: "shader_cache")
            }
            if freshCache {
                originalCache = nil; trialCache = nil
                print("Original shader cache state restored; trial cache retained separately")
            }
            if try directory.read(settingsURL.lastPathComponent) != settings {
                try directory.withWriteLock {
                    try directory.write(settings, to: settingsURL.lastPathComponent, createOnly: false, beforeCommit: { try lease.validate() })
                }
            }
            withExtendedLifetime((installation, lease)) {}
        }
        do {
            try await isolateCache()
            _ = try await preferences.setGraphicsBackend(choice, appID: 553850)
            try await GameEvaluationLaunchTests().observeLaunch()
            try await restore()
            _ = try await preferences.setGraphicsBackend(original.override, appID: 553850)
        } catch {
            try await restore()
            _ = try await preferences.setGraphicsBackend(original.override, appID: 553850)
            throw error
        }
        #expect(try await preferences.inspectGraphics(appID: 553850).override == original.override)
        #expect(try directory.read(settingsURL.lastPathComponent) == settings)
        print("Helldivers DX11 \(choice.rawValue): session stopped; original backend and game settings restored")
        print("Observation/cleanup completed; inspect renderer logs and screenshots separately for game success and API selection")
    }
}
