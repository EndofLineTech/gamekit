import Foundation
import Testing
@testable import GamekitCore

@Suite("Process observation boundaries")
struct ProcessObservationTests {
    @Test("An explicit Metal 3 comparison overrides inherited backend flags without changing the default")
    func graphicsBackendEnvironment() {
        let inherited = ["D3DM_MTL4": "1", "ROSETTA_ADVERTISE_AVX": "0"]
        let automatic = RuntimeLayout().environment(inheriting: inherited)
        #expect(automatic["D3DM_MTL4"] == nil)
        let comparison = RuntimeLayout(graphicsBackend: .metal3).environment(inheriting: inherited)
        #expect(comparison["D3DM_MTL4"] == "0")
        #expect(comparison["ROSETTA_ADVERTISE_AVX"] == "1")
        #expect(comparison["WINEDLLOVERRIDES"] == automatic["WINEDLLOVERRIDES"])
    }

    @Test("Role detection uses the executable target, not an incidental later argument")
    func executableRole() throws {
        let record = try sampleEnvironment()
        let prefix = URL(fileURLWithPath: "/owned/steam")
        let steam = "C:\\Program Files (x86)\\Steam\\Steam.exe"
        #expect(RuntimeProcessObserver.role(arguments: ["/runtime/bin/wine", steam], record: record, prefix: prefix) == .steam)
        #expect(RuntimeProcessObserver.role(arguments: ["/launcher/Windows Steam", steam], record: record, prefix: prefix) == .steam)
        #expect(RuntimeProcessObserver.role(arguments: ["/runtime/bin/wine", "cmd", "/c", "echo", steam], record: record, prefix: prefix) == .other)
        #expect(RuntimeProcessObserver.role(arguments: [steam, "-silent"], record: record, prefix: prefix) == .steam)
        let helper = prefix.appendingPathComponent("drive_c/Program Files (x86)/Steam/bin/cef/cef.win64/steamwebhelper.exe").path
        #expect(RuntimeProcessObserver.role(arguments: [helper], record: record, prefix: prefix) == .steamUI)
    }

    @Test("Bundled launcher targets are recognized only within their own prefix and client directory")
    func launcherRole() throws {
        let profile = try LauncherProfileStore.bundled("ubisoft")
        let record = try EnvironmentRecord(id: profile.id, name: profile.name,
                                           steamExecutable: profile.executable, installation: .installed)
        let prefix = URL(fileURLWithPath: "/owned/launcher")
        let directory = prefix.appendingPathComponent(profile.executable.rawValue).deletingLastPathComponent()
        let client = directory.appendingPathComponent(try #require(profile.clientExecutables.first))
        let web = directory.appendingPathComponent(try #require(profile.webExecutables.first))
        #expect(RuntimeProcessObserver.role(arguments: [profile.executable.rawValue], record: record, prefix: prefix) == .other)
        #expect(RuntimeProcessObserver.role(arguments: [prefix.appendingPathComponent(profile.executable.rawValue).path],
                                            record: record, prefix: prefix) == .launcher)
        #expect(RuntimeProcessObserver.role(arguments: [client.path], record: record, prefix: prefix) == .launcher)
        #expect(RuntimeProcessObserver.role(arguments: [web.path], record: record, prefix: prefix) == .launcherUI)
        #expect(RuntimeProcessObserver.role(arguments: ["/other/" + client.lastPathComponent], record: record, prefix: prefix) == .other)
        #expect(RuntimeProcessObserver.role(arguments: ["cmd", "/c", client.path], record: record, prefix: prefix) == .other)
        let process = ScopedRuntimeProcess(identity: .init(pid: 42, startSeconds: 1, startMicroseconds: 0),
                                           role: .launcher, sessionID: "owned")
        #expect(RuntimeProcessSnapshot(processes: [process], complete: true).observation(installation: .installed) == .launcherRunning)
        #expect(EnvironmentReconciler.reconcile(record, files: .init(prefixExists: true, executableExists: true),
                                                process: .launcherRunning, prerequisites: .ready, at: Date()).state == .running)
    }
    @Test("Wine environment does not inherit secrets or conflicting runtime controls")
    func sanitizedEnvironment() {
        let layout = RuntimeLayout(dataRoot: URL(fileURLWithPath: "/Gamekit"))
        let env = layout.environment(prefix: URL(fileURLWithPath: "/owned prefix"), session: "ours",
                                     inheriting: ["HOME": "/home", "API_KEY": "secret", "WINEPREFIX": "/other",
                                                  "DYLD_INSERT_LIBRARIES": "bad", "GAMEKIT_SESSION_ID": "foreign",
                                                  "WINEDLLOVERRIDES": "kernel32=n", "ROSETTA_ADVERTISE_AVX": "0"])
        #expect(env["HOME"] == "/home")
        #expect(env["API_KEY"] == nil && env["DYLD_INSERT_LIBRARIES"] == nil)
        #expect(env["WINEPREFIX"] == "/owned prefix" && env["GAMEKIT_SESSION_ID"] == "ours")
        #expect(env["WINEARCH"] == "win64")
        #expect(env["ROSETTA_ADVERTISE_AVX"] == "1", "Managed launches advertise the instruction extensions supported by the validated translator")
        #expect(env["WINEDLLOVERRIDES"] == "msvcp140,msvcp140_1,msvcp140_2,msvcp140_atomic_wait,vcruntime140,vcruntime140_1,concrt140=n,b")
    }
    @Test("Kernel argument parsing retains only prefix and session, not inherited Steam AppIDs")
    func argumentParsing() {
        var count: Int32 = 2
        var bytes = withUnsafeBytes(of: &count) { Data($0) }
        bytes.append(Data("/runtime/wine\0\0wine\0C:\\Program Files (x86)\\Steam\\Steam.exe\0PRIVATE_TOKEN=do-not-retain\0WINEPREFIX=/prefix with spaces\0GAMEKIT_SESSION_ID=nonce\0SteamAppId=43\0\0".utf8))
        let parsed = KernelArguments(bytes: bytes)
        #expect(parsed?.prefix == "/prefix with spaces")
        #expect(parsed?.session == "nonce")
        #expect(parsed?.arguments.count == 2)
        if let parsed {
            let mapping = GameDockNames(schemaVersion: 1, prefix: "/prefix with spaces", sessionID: "nonce",
                                        games: ["42": "Fixture"], directories: ["42": "c:\\games\\fixture\\"])
            #expect(RuntimeProcessObserver.attributedGameID(parsed, role: .other,
                                                             mapping: mapping, prefix: URL(fileURLWithPath: "/prefix with spaces")) == nil,
                    "An inherited Steam AppID without a matching game image is not a Stop target")
            #expect(RuntimeProcessObserver.attributedGameID(parsed, role: .steam,
                                                             mapping: mapping, prefix: URL(fileURLWithPath: "/prefix with spaces")) == nil,
                    "A Steam service inheriting a game identity cannot become a per-game Stop target")
        }
        #expect(KernelArguments(bytes: Data([0, 0])) == nil)
    }

    @Test("Path boundaries do not match sibling prefixes")
    func pathBoundary() {
        let root = URL(fileURLWithPath: "/owned/steam")
        #expect(RuntimeProcessObserver.isWithin("/owned/steam/bin/wine", root: root))
        #expect(!RuntimeProcessObserver.isWithin("/owned/steam-other/bin/wine", root: root))
    }

    @Test("Wine argv rewriting can leave NUL padding before intact scope environment", arguments: [0, 1, 64])
    func rewrittenArgumentPadding(padding: Int) {
        var count: Int32 = 2
        var bytes = withUnsafeBytes(of: &count) { Data($0) }
        bytes.append(Data("/runtime/wine\0\0/owned/steam/drive_c/Program Files (x86)/Steam/Steam.exe\0\0".utf8))
        bytes.append(Data(repeating: 0, count: padding))
        bytes.append(Data("PRIVATE_TOKEN=not-retained\0WINEPREFIX=/owned/steam\0GAMEKIT_SESSION_ID=owned\0\0".utf8))
        let parsed = KernelArguments(bytes: bytes)
        #expect(parsed?.arguments.count == 2)
        #expect(parsed?.prefix == "/owned/steam")
        #expect(parsed?.session == "owned")
    }

    @Test("Reused PIDs represent different process identities")
    func pidReuse() {
        #expect(ProcessIdentity(pid: 42, startSeconds: 1, startMicroseconds: 0)
            != ProcessIdentity(pid: 42, startSeconds: 2, startMicroseconds: 0))
    }

    @Test("Incomplete inventories and service-only handoff gaps do not claim idle")
    func uncertainActivity() {
        #expect(RuntimeProcessSnapshot(processes: [], complete: false).observation(installation: .installed) == .notChecked)
        let service = ScopedRuntimeProcess(identity: .init(pid: 42, startSeconds: 1, startMicroseconds: 0), role: .service, sessionID: "token")
        #expect(RuntimeProcessSnapshot(processes: [service], complete: true).observation(installation: .installing(.bootstrappingSteam)) == .notChecked)
        #expect(RuntimeProcessSnapshot(processes: [], complete: true).observation(installation: .installed) == .idle)
    }

}
