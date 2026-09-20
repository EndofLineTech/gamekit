import Foundation
import CProcessSupport
import Testing
@testable import GamekitCore

@Suite("Opt-in managed installation inspection")
struct LiveInstallationInspectionTests {
    @Test("Completed real setup is idle and repeating install preserves its record", .enabled(if: ProcessInfo.processInfo.environment["GAMEKIT_INSTALLATION_VERIFY"] == "1"))
    func verifyManagedInstallation() async throws {
        let store = try EnvironmentStore()
        let record = try #require(await store.load(SteamInstallationRecipe.environmentID))
        try #require(record.installation == .installed)
        let files = try await store.installationFiles(record.id)
        #expect(files.prefixExists && files.executableExists)
        let layout = RuntimeLayout(dataRoot: store.root)
        let snapshot = await RuntimeProcessObserver().inspect(record: record, prefix: store.prefixURL(for: record.id), layout: layout)
        #expect(snapshot.complete && snapshot.processes.isEmpty)
        let coordinator = SteamInstallationCoordinator(store: store, layout: layout, acquisition: try SteamInstallerAcquisition(root: store.root))
        let repeated = try await coordinator.install(confirmUsableUI: { Issue.record("A completed install must not restart setup"); return false })
        #expect(repeated == record)
        print("Managed installation verified: recipe=\(record.installationRecipeVersion ?? 0) revision=\(record.revision) idle=\(snapshot.complete && snapshot.processes.isEmpty) unchanged=true")
    }

    @Test("Read-only managed installation and process facts", .enabled(if: ProcessInfo.processInfo.environment["GAMEKIT_INSTALLATION_INSPECT"] == "1"))
    func inspectManagedInstallation() async throws {
        let store = try EnvironmentStore()
        let record = try #require(await store.load(SteamInstallationRecipe.environmentID))
        let files = try await store.installationFiles(record.id)
        let layout = try await RuntimeSettingsStore(store: store).layout()
        let snapshot = await RuntimeProcessObserver().inspect(record: record, prefix: store.prefixURL(for: record.id), layout: layout)
        print("Managed installation: progress=\(record.installation) revision=\(record.revision) prefix=\(files.prefixExists) executable=\(files.executableExists) complete=\(snapshot.complete)")
        for process in snapshot.processes {
            print("Managed process: pid=\(process.identity.pid) role=\(process.role) tagged=\(process.sessionID != nil)")
        }
        if let value = ProcessInfo.processInfo.environment["GAMEKIT_INSPECT_PID"], let pid = Int32(value) {
            var identity = GKProcessIdentity()
            let code = gk_identity(pid, &identity)
            let path = withUnsafeBytes(of: identity.path) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
            print("Requested PID identity: result=\(code) binary=\(URL(fileURLWithPath: path).lastPathComponent) engine=\(RuntimeProcessObserver.isWithin(path, root: layout.engine)) prefix=\(RuntimeProcessObserver.isWithin(path, root: store.prefixURL(for: record.id)))")
            var buffer: UnsafeMutablePointer<CChar>?, count = 0
            if gk_arguments(pid, &buffer, &count) == 0, let buffer {
                defer { gk_free(buffer) }
                let bytes = Data(bytes: buffer, count: count)
                let parsed = KernelArguments(bytes: bytes)
                print("Requested PID scope: parsed=\(parsed != nil) argc=\(parsed?.arguments.count ?? 0) prefixPresent=\(parsed?.prefix != nil) prefixMatches=\(parsed?.prefix == store.prefixURL(for: record.id).path) tagged=\(parsed?.session != nil)")
                let fields = bytes.dropFirst(4).split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
                print("Requested PID raw scope presence: prefix=\(fields.contains { $0.hasPrefix("WINEPREFIX=") }) tag=\(fields.contains { $0.hasPrefix("GAMEKIT_SESSION_ID=") })")
            }
        }
    }
}
