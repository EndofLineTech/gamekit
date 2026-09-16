import Foundation
import Testing
@testable import GamekitCore

@Suite("Automatic Steam readiness")
struct SteamReadinessTests {
    private func process(_ pid: Int32, role: RuntimeProcessRole, token: String = "owned") -> ScopedRuntimeProcess {
        .init(identity: .init(pid: pid, startSeconds: 1, startMicroseconds: 0), role: role, sessionID: token)
    }
    @Test("Client exit, a service or an updater window alone never means Steam UI is ready")
    func incompleteEvidence() {
        let client = process(1, role: .steam)
        #expect(!SteamReadiness.ready(snapshot: .init(processes: [client], complete: true), windowOwners: [1]))
        let helper = process(2, role: .steamUI)
        #expect(!SteamReadiness.ready(snapshot: .init(processes: [client, helper], complete: false), windowOwners: [2]))
        #expect(!SteamReadiness.ready(snapshot: .init(processes: [client, helper], complete: true), windowOwners: []))
        #expect(!SteamReadiness.ready(snapshot: .init(processes: [client, helper], complete: true), windowOwners: [1]))
    }
    @Test("A complete, consistently owned client/web-helper set with a web UI window is ready")
    func readyWindow() {
        let client = process(1, role: .steam), helper = process(2, role: .steamUI)
        #expect(SteamReadiness.ready(snapshot: .init(processes: [client, helper], complete: true), windowOwners: [2]))
        #expect(!SteamReadiness.ready(snapshot: .init(processes: [client, process(2, role: .steamUI, token: "foreign")], complete: true), windowOwners: [2]))
    }
}
