import CProcessSupport
import Darwin
import Foundation

public struct ProcessIdentity: Hashable, Sendable {
    public let pid: Int32
    public let startSeconds: UInt64
    public let startMicroseconds: UInt64
}
public enum RuntimeProcessRole: Sendable { case steam, installer, service, other }
public struct ScopedRuntimeProcess: Sendable {
    public let identity: ProcessIdentity
    public let role: RuntimeProcessRole
    public let sessionID: String?
}
public struct RuntimeProcessSnapshot: Sendable {
    public let processes: [ScopedRuntimeProcess]
    public let complete: Bool
    public func observation(installation: InstallationProgress) -> ProcessObservation {
        guard complete else { return .notChecked }
        if processes.contains(where: { $0.role == .steam }) { return .steamRunning }
        if processes.contains(where: { $0.role == .installer }), case .installing(let stage) = installation {
            return .installerRunning(stage)
        }
        // Even services can bridge an updater handoff. Do not declare an interrupted
        // installation while its prefix still has live processes of uncertain activity.
        return processes.isEmpty ? .idle : .notChecked
    }
}

struct KernelArguments {
    let arguments: [String]
    let prefix: String?
    let session: String?

    init?(bytes: Data) {
        guard bytes.count >= 4 else { return nil }
        let argc = bytes.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard argc > 0 && argc < 4096 else { return nil }
        var offset = 4
        func string() -> String? {
            guard offset < bytes.count, let end = bytes[offset...].firstIndex(of: 0) else { return nil }
            let text = String(decoding: bytes[offset..<end], as: UTF8.self)
            offset = end + 1
            return text
        }
        guard string() != nil else { return nil } // kernel executable path
        while offset < bytes.count && bytes[offset] == 0 { offset += 1 }
        var argv: [String] = []
        for _ in 0..<argc {
            guard let argument = string() else { return nil }
            argv.append(argument)
        }
        var prefix: String?, session: String?
        while let entry = string(), !entry.isEmpty {
            if entry.hasPrefix("WINEPREFIX=") { prefix = String(entry.dropFirst(11)) }
            if entry.hasPrefix("GAMEKIT_SESSION_ID=") { session = String(entry.dropFirst(19)) }
        }
        self.arguments = argv; self.prefix = prefix; self.session = session
    }
}

public struct RuntimeProcessObserver: Sendable {
    public init() {}

    public func inspect(record: EnvironmentRecord, prefix: URL, layout: RuntimeLayout) async -> RuntimeProcessSnapshot {
        await Task.detached { snapshot(record: record, prefix: prefix, layout: layout) }.value
    }

    static func isWithin(_ path: String, root: URL) -> Bool {
        let base = root.standardizedFileURL.path
        let candidate = URL(fileURLWithPath: path).standardizedFileURL.path
        return candidate == base || candidate.hasPrefix(base + "/")
    }

    static func role(arguments: [String], record: EnvironmentRecord, prefix: URL) -> RuntimeProcessRole {
        let expectedPOSIX = prefix.appendingPathComponent(record.steamExecutable.rawValue).path.lowercased()
        let expectedWindows = "c:\\" + record.steamExecutable.components.dropFirst().joined(separator: "\\").lowercased()
        func normalized(_ raw: String) -> String {
            let value = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\"")).lowercased()
            return value.hasPrefix("c:/") ? value.replacingOccurrences(of: "/", with: "\\") : value
        }
        func leaf(_ path: String) -> String { path.replacingOccurrences(of: "\\", with: "/").components(separatedBy: "/").last ?? "" }
        guard let first = arguments.first.map(normalized) else { return .other }
        let isLoader = ["wine", "wine64", "wine-preloader", "wine64-preloader"].contains(leaf(first))
        let target = isLoader && arguments.count > 1 ? normalized(arguments[1]) : first
        if target == expectedPOSIX || target == expectedWindows { return .steam }
        let posixDirectory = prefix.appendingPathComponent(record.steamExecutable.rawValue).deletingLastPathComponent().path.lowercased() + "/"
        let windowsDirectory = "c:\\" + record.steamExecutable.components.dropFirst().dropLast().joined(separator: "\\").lowercased() + "\\"
        if leaf(target) == "steamwebhelper.exe", target.hasPrefix(posixDirectory) || target.hasPrefix(windowsDirectory) { return .steam }
        if leaf(target).hasPrefix("steamsetup") && leaf(target).hasSuffix(".exe") { return .installer }
        if ["wineboot", "wineboot.exe"].contains(leaf(target)), case .installing(.creatingPrefix) = record.installation { return .installer }
        if ["wineserver", "services.exe", "winedevice.exe", "explorer.exe", "rpcss.exe", "svchost.exe", "conhost.exe", "plugplay.exe", "steamservice.exe"].contains(leaf(target)) { return .service }
        return .other
    }

    public func snapshot(record: EnvironmentRecord, prefix: URL, layout: RuntimeLayout) -> RuntimeProcessSnapshot {
        let initial = gk_user_pids(nil, 0)
        guard initial > 0 else { return .init(processes: [], complete: false) }
        var ids = [pid_t](repeating: 0, count: Int(initial) / MemoryLayout<pid_t>.stride + 128)
        let capacity = ids.count * MemoryLayout<pid_t>.stride
        let used = gk_user_pids(&ids, Int32(capacity))
        guard used > 0 && used < capacity else { return .init(processes: [], complete: false) }
        var processes: [ScopedRuntimeProcess] = [], complete = true
        for pid in ids.prefix(Int(used) / MemoryLayout<pid_t>.stride) where pid > 0 {
            var first = GKProcessIdentity()
            let read = gk_identity(pid, &first)
            if read != 0 {
                if read != ESRCH && read != ENOENT { complete = false }
                continue
            }
            if first.zombie != 0 || first.uid != getuid() { continue }
            let executable = withUnsafeBytes(of: first.path) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
            guard Self.isWithin(executable, root: layout.engine) || Self.isWithin(executable, root: prefix) else { continue }
            var buffer: UnsafeMutablePointer<CChar>?, length = 0
            let code = gk_arguments(pid, &buffer, &length)
            guard code == 0, let buffer else {
                if code != ESRCH && code != ENOENT { complete = false }
                continue
            }
            // Only Wine candidates are read. Raw argv/environment bytes never leave
            // this method; unrelated environment keys are not retained or logged.
            let parsed = KernelArguments(bytes: Data(bytes: buffer, count: length))
            gk_free(buffer)
            guard let parsed else { complete = false; continue }
            if parsed.prefix == nil && parsed.session != nil { complete = false; continue }
            guard let candidatePrefix = parsed.prefix,
                  URL(fileURLWithPath: candidatePrefix).standardizedFileURL.path == prefix.standardizedFileURL.path else { continue }
            var second = GKProcessIdentity()
            guard gk_identity(pid, &second) == 0, second.zombie == 0,
                  second.uid == first.uid,
                  second.start_seconds == first.start_seconds,
                  second.start_microseconds == first.start_microseconds else { complete = false; continue }
            let secondPath = withUnsafeBytes(of: second.path) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
            guard secondPath == executable else { complete = false; continue }
            processes.append(.init(identity: .init(pid: pid, startSeconds: first.start_seconds,
                                                   startMicroseconds: first.start_microseconds),
                                   role: Self.role(arguments: parsed.arguments, record: record, prefix: prefix),
                                   sessionID: parsed.session))
        }
        return .init(processes: processes, complete: complete)
    }
}
