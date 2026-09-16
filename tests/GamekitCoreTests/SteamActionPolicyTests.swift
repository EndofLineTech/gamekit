import Testing
@testable import GamekitCore

@Suite("Native action availability")
struct SteamActionPolicyTests {
    @Test("Installation needs both verified prerequisites and a fresh idle environment")
    func installGate() {
        let idle = RuntimeProcessSnapshot(processes: [], complete: true)
        let empty = EnvironmentFiles(prefixExists: false, executableExists: false)
        #expect(SteamActionPolicy(ready: true, installation: nil, files: empty, snapshot: idle).install)
        #expect(!SteamActionPolicy(ready: false, installation: nil, files: empty, snapshot: idle).install)
        #expect(!SteamActionPolicy(ready: true, installation: nil, files: .init(prefixExists: true, executableExists: false), snapshot: idle).install)
    }
    @Test("Busy or unknown observations disable conflicting and destructive actions")
    func uncertain() {
        let files = EnvironmentFiles(prefixExists: true, executableExists: true)
        for snapshot in [RuntimeProcessSnapshot(processes: [], complete: false), nil] {
            let policy = SteamActionPolicy(ready: true, installation: .installed, files: files, snapshot: snapshot)
            #expect(!policy.reset && !policy.launch && !policy.retry)
        }
        let busy = SteamActionPolicy(ready: true, installation: .installed, files: files,
                                     snapshot: .init(processes: [], complete: true), lifecycle: .stopped, busy: true)
        #expect(!busy.reset && !busy.launch && !busy.stop)
    }
    @Test("Installed environments offer lifecycle actions rather than reinstall or verification retry")
    func installed() {
        let policy = SteamActionPolicy(ready: true, installation: .installed, files: .init(prefixExists: true, executableExists: true),
            snapshot: .init(processes: [], complete: true), lifecycle: .stopped)
        #expect(policy.launch && policy.reset)
        #expect(!policy.install && !policy.retry && !policy.verify)
    }
    @Test("An interrupted tagged setup offers explicit stop before recovery")
    func interrupted() {
        let process = ScopedRuntimeProcess(identity: .init(pid: 1, startSeconds: 1, startMicroseconds: 0), role: .service, sessionID: "00000000-0000-0000-0000-000000000001")
        let policy = SteamActionPolicy(ready: true, installation: .installing(.bootstrappingSteam), files: .init(prefixExists: true, executableExists: true),
            snapshot: .init(processes: [process], complete: true))
        #expect(policy.stopInterrupted)
        #expect(!policy.reset && !policy.retry && !policy.install)
    }
}
