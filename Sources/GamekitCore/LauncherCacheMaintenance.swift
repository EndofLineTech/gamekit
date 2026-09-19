import Foundation

public struct LauncherCacheEntry: Identifiable, Sendable {
    public enum Status: String, Sendable { case obsolete, empty, retained, protected, cleanupPending }
    public let id: String
    public let status: Status
    public let bytes: Int64?
    let revision: RuntimeRevision
    let appID: UInt32
    let name: String
    let device: Int32
    let inode: UInt64
    public var canClean: Bool { [.obsolete, .empty, .cleanupPending].contains(status) }
}

/// Only pre-shared-PE game bundles and empty numeric probe parents are retired.
/// Current shared-pe-v2, Steam bundles, runtimes and unfamiliar entries are retained.
public actor LauncherCacheMaintenance {
    private struct Ticket: Codable {
        let schemaVersion: Int
        let name: String
        let device: Int32
        let inode: UInt64
    }
    private let store: EnvironmentStore
    private let layouts: [RuntimeLayout]
    private let idle: @Sendable () async -> Bool?
    public init(store: EnvironmentStore) {
        self.store = store
        layouts = RuntimeRevision.allCases.map { RuntimeLayout(dataRoot: store.root, profile: $0.profile) }
        idle = {
            do {
                let selected = try await RuntimeSettingsStore(store: store).layout()
                let records = try await store.loadAll()
                for record in records {
                    for layout in [selected] + RuntimeRevision.allCases.map({ RuntimeLayout(dataRoot: store.root, profile: $0.profile) }) {
                        let snapshot = await RuntimeProcessObserver().inspect(record: record, prefix: store.prefixURL(for: record.id), layout: layout)
                        guard snapshot.complete else { return nil }
                        if !snapshot.processes.isEmpty { return false }
                    }
                }
                return await Task.detached { RuntimeProcessObserver.hasProcesses(in: store.root.appendingPathComponent("Launchers")).map { !$0 } }.value
            } catch { return nil }
        }
    }
    init(store: EnvironmentStore, layouts: [RuntimeLayout], idle: @escaping @Sendable () async -> Bool?) {
        self.store = store; self.layouts = layouts; self.idle = idle
    }
    private func games(_ layout: RuntimeLayout) throws -> ManagedDirectory? {
        guard let root = try ManagedDirectory.openRoot(store.root, create: false), var launchers = try root.directory("Launchers") else { return nil }
        if layout.profile.revision != .original {
            guard let revision = try launchers.directory("Revisions")?.directory(layout.profile.revision.rawValue) else { return nil }
            launchers = revision
        }
        return try launchers.directory("Games")
    }
    private func ticket(_ parent: ManagedDirectory, name: String) throws -> Ticket? {
        guard let data = try parent.read(".cleanup-" + name + ".json") else { return nil }
        let value = try JSONDecoder().decode(Ticket.self, from: data)
        guard value.schemaVersion == 1, value.name == name, name.hasSuffix(".app"), !name.contains("/"), !name.hasPrefix(".") else { throw SteamApplicationError.invalidBundle }
        return value
    }
    private func inspectUnlocked() throws -> [LauncherCacheEntry] {
        var result: [LauncherCacheEntry] = []
        for layout in layouts {
            guard let games = try games(layout) else { continue }
            for rawID in try games.names() {
                guard let appID = UInt32(rawID), appID > 0, String(appID) == rawID,
                      let parent = try games.directory(rawID) else { continue }
                let parentIdentity = try parent.identity()
                let names = try parent.names()
                if names.allSatisfy({ $0 == ".windows-steam.lock" }) {
                    result.append(.init(id: "\(layout.profile.revision.rawValue)/\(rawID)", status: .empty, bytes: 0,
                        revision: layout.profile.revision, appID: appID, name: "", device: parentIdentity.device, inode: parentIdentity.inode))
                    continue
                }
                var candidates = Set(names.filter { $0 != ".windows-steam.lock" && !$0.hasPrefix(".cleanup-") })
                for name in names where name.hasPrefix(".cleanup-") && name.hasSuffix(".app.json") {
                    candidates.insert(String(name.dropFirst(9).dropLast(5)))
                }
                for name in candidates.sorted() {
                    var status: LauncherCacheEntry.Status = .protected
                    var bytes: Int64?
                    var identity = parentIdentity
                    if name == "shared-pe-v2" || name == "shared-pe-v2-driver-off" ||
                        name == "shared-pe-v3-dxmt-0.80-1" || name == "shared-pe-v3-dxvk-macos-1.10.3-20230507-1" { status = .retained }
                    else {
                        do {
                            if let saved = try ticket(parent, name: name) {
                                identity = (saved.device, saved.inode)
                                if let bundle = try parent.directory(name) {
                                    guard try bundle.identity() == identity else { throw EnvironmentStoreError.identityMismatch }
                                    bytes = try bundle.logicalBytes()
                                }
                                status = .cleanupPending
                            } else if name.hasSuffix(".app"), let bundle = try parent.directory(name),
                                      let data = try bundle.directory("Contents")?.read("Info.plist"),
                                      let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                                      let title = plist["CFBundleName"] as? String {
                                let game = GameApplicationIdentity(appID: appID, name: title)
                                guard game.filename + ".app" == name else { throw SteamApplicationError.invalidBundle }
                                try SteamApplicationBundle(layout: layout, game: game).validate(layout.gameApplicationsRoot.appendingPathComponent("\(rawID)/\(name)"), legacyGameCache: true)
                                identity = try bundle.identity(); bytes = try bundle.logicalBytes(); status = .obsolete
                            }
                        } catch { /* Unverifiable content is never selected for cleanup. */ }
                    }
                    result.append(.init(id: "\(layout.profile.revision.rawValue)/\(rawID)/\(name)", status: status, bytes: bytes,
                        revision: layout.profile.revision, appID: appID, name: name, device: identity.device, inode: identity.inode))
                }
            }
        }
        return result
    }
    public func inspect() async throws -> [LauncherCacheEntry] {
        let lease = try await store.installationLease()
        defer { withExtendedLifetime(lease) {} }
        return try inspectUnlocked()
    }
    public func clean(_ entry: LauncherCacheEntry, confirmed: Bool) async throws {
        guard confirmed else { throw SteamRecoveryError.confirmationRequired }
        let lease = try await store.installationLease()
        defer { withExtendedLifetime(lease) {} }
        guard !(try await RuntimeSettingsStore(store: store).isSelectionLocked()) else { throw EnvironmentStoreError.busy }
        var executionLocks: [ManagedFileLock] = []
        defer { withExtendedLifetime(executionLocks) {} }
        if let root = try ManagedDirectory.openRoot(store.root, create: false), let metadata = try root.directory("Metadata")?.directory("Environments") {
            for record in try await store.loadAll() { executionLocks.append(try metadata.acquireLock(".execution-\(record.id.rawValue).lock")) }
        }
        guard let stopped = await idle() else { throw SteamRecoveryError.observationUnavailable }
        guard stopped else { throw SteamRecoveryError.activeProcesses }
        guard entry.canClean, let current = try inspectUnlocked().first(where: { $0.id == entry.id }), current.canClean,
              current.device == entry.device, current.inode == entry.inode,
              let layout = layouts.first(where: { $0.profile.revision == entry.revision }),
              let games = try games(layout), let parent = try games.directory(String(entry.appID)) else { throw SteamApplicationError.invalidBundle }
        let lock = try parent.acquireLock(".windows-steam.lock")
        defer { withExtendedLifetime(lock) {} }
        try Task.checkCancellation()
        if entry.name.isEmpty {
            guard try parent.identity() == (entry.device, entry.inode),
                  try parent.names().allSatisfy({ $0 == ".windows-steam.lock" }) else { throw EnvironmentStoreError.conflict }
            try parent.removeRegularFile(".windows-steam.lock")
            try games.removeEmptyDirectory(String(entry.appID), identity: parent.identity())
        } else {
            let ticketName = ".cleanup-" + entry.name + ".json"
            if try ticket(parent, name: entry.name) == nil {
                try parent.write(JSONEncoder().encode(Ticket(schemaVersion: 1, name: entry.name, device: entry.device, inode: entry.inode)),
                    to: ticketName, createOnly: true, beforeCommit: {})
            }
            if try parent.directory(entry.name) != nil {
                try parent.removeStagingDirectory(entry.name, identity: (entry.device, entry.inode))
            }
            try parent.removeRegularFile(ticketName)
        }
    }
}
