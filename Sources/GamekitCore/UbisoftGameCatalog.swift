import Foundation

public enum UbisoftGameInstallState: String, Codable, Sendable { case installed, incomplete }
public enum UbisoftGameCatalogError: Error, Equatable { case notInstalled, invalidRecord, unavailable }

public struct InstalledUbisoftGame: Identifiable, Equatable, Sendable {
    public let id: UInt32
    public let name: String
    public let state: UbisoftGameInstallState
    public let icon: Data?
}

public struct UbisoftGameCatalogSnapshot: Sendable {
    public let games: [InstalledUbisoftGame]
    public let current: Bool
    public let unreadableRecords: Int
}

struct CachedUbisoftGame: Codable, Equatable, Sendable {
    let id: UInt32
    let name: String
    let folder: String
    let iconName: String?
}

private struct UbisoftCatalogDocument: Codable {
    let schemaVersion: Int
    let prefixDevice: Int32
    let prefixInode: UInt64
    let games: [CachedUbisoftGame]
}

/// Only vendor installation and uninstall keys are queried through Wine. No
/// account cache, user registry, whole system registry or game directory is read.
public struct UbisoftGameCatalog: Sendable {
    private let store: EnvironmentStore
    private let layout: RuntimeLayout
    private let profile: LauncherProfile
    private let registry: @Sendable (String) async throws -> String
    private let launch: @Sendable (UInt32) async throws -> Void

    public init(store: EnvironmentStore, layout: RuntimeLayout, profile: LauncherProfile) throws {
        try profile.validate()
        let lifecycle = try ManagedLauncherLifecycle(store: store, layout: layout, profile: profile)
        self.init(store: store, layout: layout, profile: profile,
            registry: { try await lifecycle.gameRegistry($0) }, launch: { try await lifecycle.requestGameLaunch($0) })
    }

    init(store: EnvironmentStore, layout: RuntimeLayout, profile: LauncherProfile,
         registry: @escaping @Sendable (String) async throws -> String,
         launch: @escaping @Sendable (UInt32) async throws -> Void) {
        self.store = store; self.layout = layout; self.profile = profile; self.registry = registry; self.launch = launch
    }

    private var filename: String { profile.id.rawValue + "-Games.json" }

    private func catalog() throws -> LauncherProfile.GameCatalog {
        guard let value = profile.gameCatalog else { throw UbisoftGameCatalogError.unavailable }
        return value
    }

    private func metadata(create: Bool) throws -> ManagedDirectory? {
        guard let root = try ManagedDirectory.openRoot(store.root, create: create) else { return nil }
        return try root.directory("Metadata", create: create)
    }

    private func savedGames(prefix: ManagedDirectory) throws -> [CachedUbisoftGame]? {
        guard let bytes = try metadata(create: false)?.read(filename) else { return nil }
        let document = try JSONDecoder().decode(UbisoftCatalogDocument.self, from: bytes)
        let identity = try prefix.identity()
        guard document.schemaVersion == 1, document.games.count <= 128,
              Set(document.games.map(\.id)).count == document.games.count
        else { throw UbisoftGameCatalogError.invalidRecord }
        // A volume can be renumbered after reboot. Never adopt an old cache for
        // a replacement prefix, but permit a fresh owned registry scan to renew it.
        guard document.prefixInode == identity.inode, document.prefixDevice == identity.device else { return nil }
        return document.games
    }

    private func save(_ games: [CachedUbisoftGame], prefix: ManagedDirectory) throws {
        let identity = try prefix.identity()
        let data = try JSONEncoder().encode(UbisoftCatalogDocument(schemaVersion: 1,
            prefixDevice: identity.device, prefixInode: identity.inode, games: games))
        guard let directory = try metadata(create: true) else { throw EnvironmentStoreError.notFound }
        try directory.withWriteLock { try directory.write(data, to: filename, createOnly: false, beforeCommit: {}) }
    }

    public func scan() async throws -> UbisoftGameCatalogSnapshot {
        let spec = try catalog()
        guard let record = try await store.load(profile.id), record.installation == .installed,
              record.runtime == layout.profile.identity, record.steamExecutable == profile.executable,
              record.installer?.source == profile.installer.url, record.installer?.sha256 == profile.installer.sha256
        else { return .init(games: [], current: true, unreadableRecords: 0) }
        let prefixURL = try await store.checkedPrefixURL(for: profile.id)
        guard let prefix = try ManagedDirectory.openRoot(prefixURL, create: false) else { throw UbisoftGameCatalogError.notInstalled }
        let previous: [CachedUbisoftGame]
        do { previous = try savedGames(prefix: prefix) ?? [] }
        catch UbisoftGameCatalogError.invalidRecord { previous = [] }
        catch is DecodingError { previous = [] }
        let installs: String
        do { installs = try await registry(spec.installsRegistryKey) }
        catch ManagedLauncherLifecycleError.observationUnavailable {
            return try snapshot(previous, prefix: prefixURL, spec: spec, current: false, unreadable: 0)
        }
        let entries = try Self.installEntries(installs, spec: spec)
        var records: [CachedUbisoftGame] = [], rejected = entries.rejected
        for (id, installDir) in entries.values.sorted(by: { $0.key < $1.key }) {
            do {
                let key = spec.uninstallRegistryKey + "\\" + spec.uninstallKeyPrefix + String(id)
                let uninstall = try await registry(key)
                records.append(try Self.record(id: id, installedAt: installDir, uninstall: uninstall, spec: spec))
            } catch { rejected += 1 }
        }
        guard records.count <= 128 else { throw UbisoftGameCatalogError.invalidRecord }
        if rejected > 0 {
            records += previous.filter { old in !records.contains(where: { $0.id == old.id }) }
        }
        guard records.count <= 128 else { throw UbisoftGameCatalogError.invalidRecord }
        let result = try snapshot(records, prefix: prefixURL, spec: spec, current: rejected == 0, unreadable: rejected)
        if rejected == 0 {
            // Verify every cached entry before writing, then recheck the prefix
            // identity; a redirected folder must never publish a trusted cache.
            guard let current = try ManagedDirectory.openRoot(prefixURL, create: false),
                  try current.identity() == prefix.identity() else { throw UbisoftGameCatalogError.unavailable }
            try save(records, prefix: prefix)
        }
        return result
    }

    public func requestPlay(_ id: UInt32) async throws {
        guard id > 0 else { throw UbisoftGameCatalogError.notInstalled }
        let result = try await scan()
        guard result.current, result.unreadableRecords == 0,
              result.games.contains(where: { $0.id == id && $0.state == .installed })
        else { throw UbisoftGameCatalogError.unavailable }
        try await launch(id)
    }

    private func snapshot(_ records: [CachedUbisoftGame], prefix: URL, spec: LauncherProfile.GameCatalog,
                          current: Bool, unreadable: Int) throws -> UbisoftGameCatalogSnapshot {
        let iconRoot = try ManagedDirectory.openRoot(prefix.appendingPathComponent(spec.iconDirectory.rawValue), create: false)
        var games: [InstalledUbisoftGame] = []
        for record in records {
            guard let folder = try Self.gameFolder(record.folder, spec: spec),
                  record.id > 0, Self.validName(record.name),
                  record.iconName.map({ $0.range(of: "\\A[0-9a-f]{32}\\.ico\\z", options: .regularExpression) != nil }) != false
            else { throw UbisoftGameCatalogError.invalidRecord }
            let directory = try ManagedDirectory.openRoot(prefix.appendingPathComponent(folder.rawValue), create: false)
            let markers = try spec.installMarkers.map { try directory?.regularFileSize($0) }
            let state: UbisoftGameInstallState = markers.allSatisfy({ ($0 ?? 0) > 0 }) ? .installed : .incomplete
            let icon = record.iconName.flatMap { try? iconRoot?.read($0, maximumBytes: 262_144) } ?? nil
            games.append(.init(id: record.id, name: record.name, state: state, icon: icon))
        }
        return .init(games: games.sorted {
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }, current: current, unreadableRecords: unreadable)
    }

    private static func validName(_ name: String) -> Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && name.count <= 256 &&
            name.rangeOfCharacter(from: .controlCharacters) == nil
    }

    private static func windowsPath(_ raw: String) -> RelativePath? {
        let path = raw.replacingOccurrences(of: "\\", with: "/").trimmingCharacters(in: .whitespacesAndNewlines)
        guard path.lowercased().hasPrefix("c:/") else { return nil }
        let remainder = String(path.dropFirst(3)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return try? RelativePath("drive_c/" + remainder)
    }

    private static func gameFolder(_ leaf: String, spec: LauncherProfile.GameCatalog) throws -> RelativePath? {
        guard !leaf.isEmpty, leaf.count <= 160, leaf.rangeOfCharacter(from: .controlCharacters) == nil else { return nil }
        return try? RelativePath(spec.gamesDirectory.rawValue + "/" + leaf)
    }

    private struct RegistrySection {
        let key: String
        var values: [String: String]
    }

    private static func sections(_ output: String) throws -> [RegistrySection] {
        guard output.utf8.count <= 65_536, !output.utf8.contains(0) else { throw UbisoftGameCatalogError.invalidRecord }
        var sections: [RegistrySection] = []
        for line in output.components(separatedBy: .newlines) {
            let stripped = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if stripped.isEmpty { continue }
            if stripped.hasPrefix("HKEY_LOCAL_MACHINE\\") {
                guard sections.count < 129 else { throw UbisoftGameCatalogError.invalidRecord }
                sections.append(.init(key: stripped, values: [:]))
            } else if let range = stripped.range(of: "REG_SZ") {
                guard !sections.isEmpty else { throw UbisoftGameCatalogError.invalidRecord }
                let key = stripped[..<range.lowerBound].trimmingCharacters(in: .whitespaces)
                let value = stripped[range.upperBound...].trimmingCharacters(in: .whitespaces)
                guard !key.isEmpty, sections[sections.count - 1].values[key] == nil else { throw UbisoftGameCatalogError.invalidRecord }
                sections[sections.count - 1].values[key] = value
            } else if stripped.contains("REG_DWORD") || stripped.contains("REG_BINARY") { continue }
            else { throw UbisoftGameCatalogError.invalidRecord }
        }
        return sections
    }

    static func installEntries(_ output: String, spec: LauncherProfile.GameCatalog) throws -> (values: [UInt32: String], rejected: Int) {
        let root = spec.installsRegistryKey.replacingOccurrences(of: "HKLM", with: "HKEY_LOCAL_MACHINE")
        var values: [UInt32: String] = [:], rejected = 0
        for section in try sections(output) {
            if section.key.caseInsensitiveCompare(root) == .orderedSame { continue }
            let prefix = root + "\\"
            guard section.key.lowercased().hasPrefix(prefix.lowercased()),
                  let id = UInt32(section.key.dropFirst(prefix.count)), id > 0,
                  values[id] == nil, let path = section.values["InstallDir"]
            else { rejected += 1; continue }
            values[id] = path
        }
        return (values, rejected)
    }

    static func record(id: UInt32, installedAt path: String, uninstall: String,
                       spec: LauncherProfile.GameCatalog) throws -> CachedUbisoftGame {
        let expected = (spec.uninstallRegistryKey + "\\" + spec.uninstallKeyPrefix + String(id))
            .replacingOccurrences(of: "HKLM", with: "HKEY_LOCAL_MACHINE")
        let sections = try sections(uninstall)
        guard sections.count == 1, sections[0].key.caseInsensitiveCompare(expected) == .orderedSame,
              let installed = windowsPath(path), let location = sections[0].values["InstallLocation"].flatMap(windowsPath),
              installed == location, let name = sections[0].values["DisplayName"], validName(name),
              sections[0].values["Publisher"] == spec.publisher,
              installed.components.starts(with: spec.gamesDirectory.components),
              installed.components.count == spec.gamesDirectory.components.count + 1
        else { throw UbisoftGameCatalogError.invalidRecord }
        let icon = sections[0].values["DisplayIcon"].flatMap(windowsPath)
        let iconName: String? = icon.flatMap { path in
            let parts = path.components
            return parts.starts(with: spec.iconDirectory.components) && parts.count == spec.iconDirectory.components.count + 1 &&
                (parts.last?.range(of: "\\A[0-9a-f]{32}\\.ico\\z", options: .regularExpression) != nil)
                ? parts.last : nil
        }
        guard let folder = installed.components.last else { throw UbisoftGameCatalogError.invalidRecord }
        return .init(id: id, name: name, folder: folder, iconName: iconName)
    }
}
