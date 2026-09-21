import Foundation
import Testing
@testable import GamekitCore

@Suite("Opt-in legacy display observation")
struct LegacyDisplayProbeTests {
    @Test("Read display modes in a disposable prefix and remove it after scoped shutdown",
          .enabled(if: ProcessInfo.processInfo.environment["GAMEKIT_LEGACY_DISPLAY_PROBE"] != nil))
    func observe() async throws {
        let probe = try #require(ProcessInfo.processInfo.environment["GAMEKIT_LEGACY_DISPLAY_PROBE"])
        let desktop = ProcessInfo.processInfo.environment["GAMEKIT_LEGACY_DESKTOP"]
        let parameters = GameFixtures.desktop
        let requestedSize = try #require(parameters.size)
        try #require(desktop == nil || parameters.candidateSizes?.contains(desktop!) == true)
        let appDesktop = ProcessInfo.processInfo.environment["GAMEKIT_LEGACY_APP_DESKTOP"] == "1"
        try #require(!appDesktop || desktop == nil)
        let selected = try await RuntimeSettingsStore(store: EnvironmentStore()).layout()
        let root = try ManagedDirectory.canonicalRoot(FileManager.default.temporaryDirectory.appendingPathComponent("Gamekit display " + UUID().uuidString))
        let store = try EnvironmentStore(root: root)
        let layout = RuntimeLayout(dataRoot: root, profile: selected.profile, bundle: selected.bundle, graphicsBackend: selected.graphicsBackend)
        let id = try EnvironmentID("display-probe")
        _ = try await store.create(.init(id: id, name: "Legacy display probe", runtime: layout.profile.identity, installation: .installing(.creatingPrefix)))
        try FileManager.default.createDirectory(at: store.prefixURL(for: id), withIntermediateDirectories: true)
        if appDesktop {
            let name = URL(fileURLWithPath: probe).lastPathComponent
            for arguments in [
                ["reg.exe", "add", "HKCU\\Software\\Wine\\Explorer\\Desktops", "/v", "GamekitLegacyProbe", "/t", "REG_SZ", "/d", requestedSize, "/f"],
                ["reg.exe", "add", "HKCU\\Software\\Wine\\AppDefaults\\\(name)\\Explorer", "/v", "Desktop", "/t", "REG_SZ", "/d", "GamekitLegacyProbe", "/f"]
            ] {
                let setting = try await RuntimeSession.start(store: store, id: id, layout: layout, arguments: arguments, timeout: 60)
                let configured = await setting.command.result()
                _ = try await setting.stop()
                try #require(configured.termination == .exited(0))
            }
        }
        let windowsProbe = "Z:" + probe.replacingOccurrences(of: "/", with: "\\")
        let reportPath = "C:\\legacy-display-probe.txt"
        let arguments = desktop.map { ["explorer.exe", "/desktop=GamekitLegacyProbe,\($0)", windowsProbe, requestedSize, reportPath] } ?? [probe, requestedSize, reportPath]
        let session = try await RuntimeSession.start(store: store, id: id, layout: layout, arguments: arguments, timeout: 60)
        let result = await session.command.result()
        var report = ""
        for _ in 0..<50 {
            if let bytes = try? ManagedDirectory.openRoot(store.prefixURL(for: id), create: false)?.directory("drive_c")?.read("legacy-display-probe.txt") {
                report = String(decoding: bytes, as: UTF8.self)
                if report.contains("END legacy display probe") { break }
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        _ = try await session.stop()
        let stopped = try await session.snapshot()
        try #require(stopped.complete && stopped.processes.isEmpty)
        print(result.stdoutText)
        print(report)
        print(result.stderrText)
        try FileManager.default.removeItem(at: root)
        print("Disposable prefix removed after verified shutdown")
        #expect(result.termination == .exited(0))
        #expect(report.contains("END legacy display probe"), "The child probe must actually finish, not only explorer.exe")
    }
}
