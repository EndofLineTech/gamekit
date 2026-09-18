import CProcessSupport
import Foundation
import Testing
@testable import GamekitCore

@Suite("Opt-in Helldivers graphics-backend comparison")
struct HelldiversGraphicsBackendTests {
    @Test("Start a fresh managed Metal 3 session for a user-controlled comparison",
          .enabled(if: ProcessInfo.processInfo.environment["GAMEKIT_HELLDIVERS_METAL3"] == "1"))
    func launchMetal3() async throws {
        let store = try EnvironmentStore()
        let selected = try await RuntimeSettingsStore(store: store).layout()
        try #require(selected.profile.revision == .textInput1)
        let package = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["GAMEKIT_E6_PACKAGE"]))
        let layout = RuntimeLayout(dataRoot: store.root, profile: selected.profile, bundle: selected.bundle,
            identityHelper: package.appendingPathComponent("Contents/Frameworks/WineGameIdentity.dylib"), graphicsBackend: .metal3)
        try #require(layout.hasGameIdentityHelper)
        let record = try #require(await store.load(SteamInstallationRecipe.environmentID))
        let prefix = store.prefixURL(for: record.id)
        let observer = RuntimeProcessObserver()
        let initial = await observer.inspect(record: record, prefix: prefix, layout: layout)
        try #require(initial.complete && !initial.processes.contains { $0.role == .other }, "Exit managed games before changing the session backend")
        let lifecycle = SteamLifecycle(store: store, layout: layout)
        _ = try await lifecycle.stop()
        do {
            try await lifecycle.launchGame(appID: 553850)
            for _ in 0..<60 {
                let snapshot = await observer.inspect(record: record, prefix: prefix, layout: layout)
                try #require(snapshot.complete)
                var sawSteam = false, sawGame = false
                for process in snapshot.processes where process.role == .steam || process.role == .other {
                    var buffer: UnsafeMutablePointer<CChar>?, length = 0
                    guard gk_arguments(process.identity.pid, &buffer, &length) == 0, let buffer else { continue }
                    let bytes = Data(bytes: buffer, count: length)
                    gk_free(buffer)
                    let fields = bytes.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
                    let arguments = KernelArguments(bytes: bytes)?.arguments ?? []
                    let image = arguments.first { $0.lowercased().hasSuffix(".exe") }
                    let isGame = image?.replacingOccurrences(of: "\\", with: "/").components(separatedBy: "/").last?.lowercased() == "helldivers2.exe"
                    if process.role == .steam || isGame {
                        try #require(fields.contains("D3DM_MTL4=0"), "The managed process must actually inherit the comparison setting")
                        if isGame {
                            sawGame = true
                            print("Verified Helldivers comparison PID=\(process.identity.pid)")
                        }
                        if process.role == .steam { sawSteam = true }
                    }
                }
                if sawSteam && sawGame {
                    print("D3DM_MTL4=0 verified in managed Steam and Helldivers. Session left running for the user's comparison; normal Steam restart restores the default backend.")
                    return
                }
                try await Task.sleep(for: .milliseconds(500))
            }
            throw SteamLifecycleError.observationUnavailable
        } catch {
            _ = try await lifecycle.stop()
            throw error
        }
    }
}
