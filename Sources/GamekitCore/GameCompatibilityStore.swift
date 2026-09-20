import Foundation

public enum GameCompatibilityError: Error, Equatable { case unsupportedGame, unsupportedRegistry, unsupportedPresentation, driverRuntimeRequired }
public enum GameCaptureOverride: String, CaseIterable, Sendable {
    case inherit, enabled, disabled
    public var title: String {
        switch self {
        case .inherit: "Inherit Wine default"
        case .enabled: "Enabled for this game"
        case .disabled: "Disabled for this game"
        }
    }
}
public enum GameGraphicsOverride: String, Codable, CaseIterable, Sendable {
    case inherit, automatic, metal3, dxvk, dxmt
    public var title: String {
        switch self {
        case .inherit: "Use shared default"
        case .automatic: D3DMetalBackend.automatic.title
        case .metal3: D3DMetalBackend.metal3.title
        case .dxvk: GraphicsBackend.dxvk.title
        case .dxmt: GraphicsBackend.dxmt.title
        }
    }
    public func effectiveBackend(shared: D3DMetalBackend) -> D3DMetalBackend {
        switch self {
        case .inherit: shared
        case .automatic: .automatic
        case .metal3: .metal3
        case .dxvk: .dxvk
        case .dxmt: .dxmt
        }
    }
}
public struct GameGraphicsSnapshot: Sendable {
    public let override: GameGraphicsOverride
    public let sharedBackend: D3DMetalBackend
    public let sessionLocked: Bool
    public var effectiveBackend: D3DMetalBackend { override.effectiveBackend(shared: sharedBackend) }
}
public struct GameCompatibilitySnapshot: Sendable {
    public let capture: GameCaptureOverride
    public let inheritedCapture: Bool
    public let graphicsBackend: D3DMetalBackend
    public let sessionLocked: Bool
    public let fullscreenSpace: Bool
    public let driverCompatibility: Bool
    public let driverCompatibilityAvailable: Bool
    public var effectiveCapture: Bool { capture == .enabled || (capture == .inherit && inheritedCapture) }
}

struct GameCompatibilityPreferences: Codable {
    var schemaVersion = 2
    var driverVersions: [String: Bool] = [:]
    var graphicsBackends: [String: GameGraphicsOverride] = [:]
    init() {}
    private enum CodingKeys: String, CodingKey { case schemaVersion, driverVersions, graphicsBackends }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
        driverVersions = try values.decode([String: Bool].self, forKey: .driverVersions)
        if schemaVersion == 1 {
            guard !values.contains(.graphicsBackends) else { throw GameCompatibilityError.unsupportedPresentation }
            graphicsBackends = [:]
        } else {
            graphicsBackends = try values.decode([String: GameGraphicsOverride].self, forKey: .graphicsBackends)
        }
    }

    static func read(root: URL) throws -> Self {
        guard let metadata = try ManagedDirectory.openRoot(root, create: false)?.directory("Metadata"),
              let data = try metadata.read("GameCompatibility.json") else { return .init() }
        var preferences = try JSONDecoder().decode(Self.self, from: data)
        guard (preferences.schemaVersion == 1 && preferences.graphicsBackends.isEmpty || preferences.schemaVersion == 2),
              preferences.driverVersions.count <= 512, preferences.driverVersions.keys.allSatisfy(canonicalAppID), preferences.graphicsBackends.count <= 512,
              preferences.graphicsBackends.keys.allSatisfy({ key in
                  guard let id = UInt32(key), id > 0 else { return false }
                  return String(id) == key
              })
        else { throw GameCompatibilityError.unsupportedPresentation }
        preferences.schemaVersion = 2
        return preferences
    }

    func driverEnabled(appID: UInt32, revision: RuntimeRevision, root: URL? = nil) -> Bool {
        guard let driver = gameExecution(appID: appID, root: root).driver, driver.available(revision: revision) else { return false }
        return driverVersions[String(appID)] ?? driver.defaultEnabled
    }
}

private func canonicalAppID(_ key: String) -> Bool {
    guard let id = UInt32(key), id > 0 else { return false }
    return String(id) == key
}

func gameExecution(appID: UInt32, root: URL? = nil) -> GameExecutionParameters {
    (root.flatMap { GameProfileStore.resolved(appID: appID, root: $0)?.profile } ?? GameProfileStore.bundled(appID: appID))?.execution ?? .init()
}

struct GamePresentationPreferences: Codable {
    var schemaVersion = 1
    var fullscreenSpaces: [String: Bool] = [:]
    static func read(root: URL) throws -> Self {
        guard let directory = try ManagedDirectory.openRoot(root, create: false)?.directory("Metadata"),
              let data = try directory.read("GamePresentation.json") else { return .init() }
        let value = try JSONDecoder().decode(Self.self, from: data)
        guard value.schemaVersion == 1, value.fullscreenSpaces.count <= 512,
              value.fullscreenSpaces.keys.allSatisfy(canonicalAppID) else { throw GameCompatibilityError.unsupportedPresentation }
        return value
    }
}

/// Narrow, lossless edit of the two known Wine registry sections. The existing
/// prefix is the source of truth, so previously accepted settings are not reset
/// merely by opening Gamekit. No game configuration or binary is modified.
struct GameCaptureRegistry {
    private let appSection: String
    private let inheritedDefault: Bool
    private static let globalSection = #"Software\\Wine\\Mac Driver"#
    private static let key = "\"CaptureDisplaysForFullscreen\""
    private let lines: [String]
    init(_ data: Data, executable: String, inheritedDefault: Bool = false) throws {
        guard executable.range(of: #"\A[a-z0-9][a-z0-9 ._()'-]{0,200}\.exe\z"#, options: .regularExpression) != nil
        else { throw GameCompatibilityError.unsupportedRegistry }
        appSection = #"Software\\Wine\\AppDefaults\\"# + executable + #"\\Mac Driver"#
        self.inheritedDefault = inheritedDefault
        guard let text = String(data: data, encoding: .utf8), !text.contains("\0"),
              text.hasPrefix("WINE REGISTRY Version 2\n") else { throw GameCompatibilityError.unsupportedRegistry }
        lines = text.components(separatedBy: "\n")
    }
    private func section(_ wanted: String) throws -> Range<Int>? {
        var start: Int?
        var result: Range<Int>?
        for (index, line) in lines.enumerated() where line.hasPrefix("[") {
            guard let end = line.firstIndex(of: "]") else { throw GameCompatibilityError.unsupportedRegistry }
            if let current = start { result = current..<index; start = nil }
            let name = String(line[line.index(after: line.startIndex)..<end])
            if name.lowercased() == wanted.lowercased() {
                guard result == nil else { throw GameCompatibilityError.unsupportedRegistry }
                start = index
            }
        }
        return start.map { $0..<lines.count } ?? result
    }
    private func value(in section: String) throws -> (index: Int, enabled: Bool)? {
        guard let range = try self.section(section) else { return nil }
        var found: (Int, Bool)?
        for index in range.dropFirst() {
            let line = lines[index].trimmingCharacters(in: .whitespaces)
            guard line.lowercased().hasPrefix(Self.key.lowercased()) else { continue }
            guard found == nil else { throw GameCompatibilityError.unsupportedRegistry }
            let suffix = line.dropFirst(Self.key.count).trimmingCharacters(in: .whitespaces)
            guard suffix == "=\"y\"" || suffix == "=\"n\"" else { throw GameCompatibilityError.unsupportedRegistry }
            found = (index, suffix == "=\"y\"")
        }
        return found
    }
    var capture: GameCaptureOverride {
        get throws { try value(in: appSection).map { $0.enabled ? .enabled : .disabled } ?? .inherit }
    }
    var inheritedCapture: Bool {
        get throws { try value(in: Self.globalSection)?.enabled ?? inheritedDefault }
    }
    func setting(_ setting: GameCaptureOverride) throws -> Data {
        _ = try inheritedCapture
        let previous = try value(in: appSection)
        var edited = lines
        let line = Self.key + (setting == .enabled ? "=\"y\"" : "=\"n\"")
        if let previous {
            if setting == .inherit { edited.remove(at: previous.index) }
            else { edited[previous.index] = line }
        } else if setting != .inherit {
            if let range = try section(appSection) { edited.insert(line, at: range.lowerBound + 1) }
            else { edited += ["", "[\(appSection)]", line, ""] }
        }
        return Data(edited.joined(separator: "\n").utf8)
    }
}

public actor GameCompatibilityStore {
    private let store: EnvironmentStore
    private let observe: @Sendable (EnvironmentRecord, URL, RuntimeLayout) async -> RuntimeProcessSnapshot
    public static func supports(_ appID: UInt32, root: URL? = nil) -> Bool { gameExecution(appID: appID, root: root).hasSettings }
    public init(store: EnvironmentStore) {
        self.store = store
        observe = { record, prefix, layout in await RuntimeProcessObserver().inspect(record: record, prefix: prefix, layout: layout) }
    }
    init(store: EnvironmentStore, observe: @escaping @Sendable (EnvironmentRecord, URL, RuntimeLayout) async -> RuntimeProcessSnapshot) {
        self.store = store; self.observe = observe
    }
    private func record(_ appID: UInt32, specialized: Bool = true) async throws -> EnvironmentRecord {
        guard !specialized || Self.supports(appID, root: store.root) else { throw GameCompatibilityError.unsupportedGame }
        guard let record = try await store.load(SteamInstallationRecipe.environmentID), record.installation == .installed,
              record.installationRecipeVersion == 1, record.runtime == RuntimeProfile.sikarugir.identity,
              record.steamExecutable == .steamDefault,
              try SteamGameLibrary.scan(prefix: store.prefixURL(for: record.id), steamExecutable: record.steamExecutable).games.contains(where: { $0.id == appID && $0.state == .ready })
        else { throw SteamGameLibraryError.notInstalled }
        return record
    }
    private func prefix(_ record: EnvironmentRecord) throws -> ManagedDirectory {
        guard let root = try ManagedDirectory.openRoot(store.root, create: false),
              let prefix = try root.directory("Environments")?.directory(record.id.rawValue) else { throw EnvironmentStoreError.notFound }
        return prefix
    }
    private func registry(_ prefix: ManagedDirectory) throws -> Data {
        guard let data = try prefix.read("user.reg", maximumBytes: 32 * 1024 * 1024) else { throw GameCompatibilityError.unsupportedRegistry }
        return data
    }
    private func snapshot(_ data: Data, appID: UInt32, layout: RuntimeLayout, locked: Bool) throws -> GameCompatibilitySnapshot {
        let execution = gameExecution(appID: appID, root: store.root)
        guard let executable = execution.executable else { throw GameCompatibilityError.unsupportedGame }
        let registry = try execution.capture.map { try GameCaptureRegistry(data, executable: executable, inheritedDefault: $0.inheritedDefault) }
        return try .init(capture: registry?.capture ?? .inherit, inheritedCapture: registry?.inheritedCapture ?? false,
                         graphicsBackend: layout.graphicsBackend, sessionLocked: locked,
                          fullscreenSpace: GamePresentationPreferences.read(root: store.root).fullscreenSpaces[String(appID)] ?? execution.fullscreenSpace?.defaultEnabled ?? false,
                          driverCompatibility: GameCompatibilityPreferences.read(root: store.root).driverEnabled(appID: appID, revision: layout.profile.revision, root: store.root),
                          driverCompatibilityAvailable: execution.driver?.available(revision: layout.profile.revision) == true)
    }
    public func inspect(appID: UInt32) async throws -> GameCompatibilitySnapshot {
        let installation = try await store.installationLease()
        defer { withExtendedLifetime(installation) {} }
        let record = try await record(appID)
        let settings = RuntimeSettingsStore(store: store)
        return try await snapshot(registry(prefix(record)), appID: appID, layout: settings.layout(), locked: settings.isSelectionLocked())
    }

    public func inspectGraphics(appID: UInt32) async throws -> GameGraphicsSnapshot {
        let installation = try await store.installationLease()
        defer { withExtendedLifetime(installation) {} }
        _ = try await record(appID, specialized: false)
        let settings = RuntimeSettingsStore(store: store)
        return try await .init(override: GameCompatibilityPreferences.read(root: store.root).graphicsBackends[String(appID)] ?? .inherit,
                              sharedBackend: settings.layout().graphicsBackend, sessionLocked: settings.isSelectionLocked())
    }

    @discardableResult public func setGraphicsBackend(_ override: GameGraphicsOverride, appID: UInt32) async throws -> GameGraphicsSnapshot {
        let installation = try await store.installationLease()
        defer { withExtendedLifetime(installation) {} }
        let record = try await record(appID, specialized: false)
        let settings = RuntimeSettingsStore(store: store)
        guard !(try await settings.isSelectionLocked()) else { throw EnvironmentStoreError.busy }
        let execution = try await store.executionLease(for: record.id)
        defer { withExtendedLifetime(execution) {} }
        let selected = try await settings.layout()
        for layout in [selected] + RuntimeRevision.allCases.map({ RuntimeLayout(dataRoot: store.root, profile: $0.profile) }) {
            let observed = await observe(record, execution.prefix, layout)
            guard observed.complete else { throw SteamRecoveryError.observationUnavailable }
            guard observed.processes.isEmpty else { throw SteamRecoveryError.activeProcesses }
        }
        try execution.validate(); try Task.checkCancellation()
        try GraphicsPayload(backend: override.effectiveBackend(shared: selected.graphicsBackend))?.validate(layout: selected)
        var preferences = try GameCompatibilityPreferences.read(root: store.root)
        if override == .inherit { preferences.graphicsBackends.removeValue(forKey: String(appID)) }
        else { preferences.graphicsBackends[String(appID)] = override }
        guard let metadata = try ManagedDirectory.openRoot(store.root, create: false)?.directory("Metadata") else { throw EnvironmentStoreError.notFound }
        try metadata.withWriteLock {
            try metadata.write(JSONEncoder().encode(preferences), to: "GameCompatibility.json", createOnly: false, beforeCommit: { try execution.validate() })
        }
        let saved = try GameCompatibilityPreferences.read(root: store.root)
        return .init(override: saved.graphicsBackends[String(appID)] ?? .inherit, sharedBackend: selected.graphicsBackend, sessionLocked: false)
    }

    @discardableResult public func setDriverCompatibility(_ enabled: Bool, appID: UInt32) async throws -> GameCompatibilitySnapshot {
        let installation = try await store.installationLease()
        defer { withExtendedLifetime(installation) {} }
        let record = try await record(appID)
        let settings = RuntimeSettingsStore(store: store)
        guard !(try await settings.isSelectionLocked()) else { throw EnvironmentStoreError.busy }
        let execution = try await store.executionLease(for: record.id)
        defer { withExtendedLifetime(execution) {} }
        let selected = try await settings.layout()
        guard let driver = gameExecution(appID: appID, root: store.root).driver else { throw GameCompatibilityError.unsupportedGame }
        guard !enabled || driver.available(revision: selected.profile.revision) else { throw GameCompatibilityError.driverRuntimeRequired }
        for layout in [selected] + RuntimeRevision.allCases.map({ RuntimeLayout(dataRoot: store.root, profile: $0.profile) }) {
            let observed = await observe(record, execution.prefix, layout)
            guard observed.complete else { throw SteamRecoveryError.observationUnavailable }
            guard observed.processes.isEmpty else { throw SteamRecoveryError.activeProcesses }
        }
        try execution.validate(); try Task.checkCancellation()
        _ = try snapshot(registry(prefix(record)), appID: appID, layout: selected, locked: false)
        var preferences = try GameCompatibilityPreferences.read(root: store.root)
        preferences.driverVersions[String(appID)] = enabled
        guard let metadata = try ManagedDirectory.openRoot(store.root, create: false)?.directory("Metadata") else { throw EnvironmentStoreError.notFound }
        try metadata.withWriteLock {
            try metadata.write(JSONEncoder().encode(preferences), to: "GameCompatibility.json", createOnly: false, beforeCommit: { try execution.validate() })
        }
        return try snapshot(registry(prefix(record)), appID: appID, layout: selected, locked: false)
    }
    @discardableResult public func setCapture(_ capture: GameCaptureOverride, appID: UInt32) async throws -> GameCompatibilitySnapshot {
        let installation = try await store.installationLease()
        defer { withExtendedLifetime(installation) {} }
        let record = try await record(appID)
        let settings = RuntimeSettingsStore(store: store)
        guard !(try await settings.isSelectionLocked()) else { throw EnvironmentStoreError.busy }
        let execution = try await store.executionLease(for: record.id)
        defer { withExtendedLifetime(execution) {} }
        let selected = try await settings.layout()
        for layout in [selected] + RuntimeRevision.allCases.map({ RuntimeLayout(dataRoot: store.root, profile: $0.profile) }) {
            let observed = await observe(record, execution.prefix, layout)
            guard observed.complete else { throw SteamRecoveryError.observationUnavailable }
            guard observed.processes.isEmpty else { throw SteamRecoveryError.activeProcesses }
        }
        try execution.validate(); try Task.checkCancellation()
        let directory = try prefix(record)
        let original = try registry(directory)
        _ = try snapshot(original, appID: appID, layout: selected, locked: false)
        let parameters = gameExecution(appID: appID, root: store.root)
        guard let executable = parameters.executable, let configuration = parameters.capture else { throw GameCompatibilityError.unsupportedGame }
        let updated = try GameCaptureRegistry(original, executable: executable, inheritedDefault: configuration.inheritedDefault).setting(capture)
        try directory.withWriteLock {
            try directory.write(updated, to: "user.reg", createOnly: false, temporaryPrefix: ".game-compatibility-", beforeCommit: {
                try execution.validate()
                guard try registry(directory) == original else { throw EnvironmentStoreError.conflict }
            })
        }
        let result = try snapshot(registry(directory), appID: appID, layout: selected, locked: false)
        guard result.capture == capture else { throw GameCompatibilityError.unsupportedRegistry }
        return result
    }

    @discardableResult public func setFullscreenSpace(_ enabled: Bool, appID: UInt32) async throws -> GameCompatibilitySnapshot {
        let installation = try await store.installationLease()
        defer { withExtendedLifetime(installation) {} }
        let record = try await record(appID)
        let settings = RuntimeSettingsStore(store: store)
        guard !(try await settings.isSelectionLocked()) else { throw EnvironmentStoreError.busy }
        let execution = try await store.executionLease(for: record.id)
        defer { withExtendedLifetime(execution) {} }
        let selected = try await settings.layout()
        for layout in [selected] + RuntimeRevision.allCases.map({ RuntimeLayout(dataRoot: store.root, profile: $0.profile) }) {
            let observed = await observe(record, execution.prefix, layout)
            guard observed.complete else { throw SteamRecoveryError.observationUnavailable }
            guard observed.processes.isEmpty else { throw SteamRecoveryError.activeProcesses }
        }
        try execution.validate(); try Task.checkCancellation()
        guard gameExecution(appID: appID, root: store.root).fullscreenSpace != nil else { throw GameCompatibilityError.unsupportedGame }
        _ = try snapshot(registry(prefix(record)), appID: appID, layout: selected, locked: false)
        var preferences = try GamePresentationPreferences.read(root: store.root)
        preferences.fullscreenSpaces[String(appID)] = enabled
        guard let metadata = try ManagedDirectory.openRoot(store.root, create: false)?.directory("Metadata") else { throw EnvironmentStoreError.notFound }
        try metadata.withWriteLock {
            try metadata.write(JSONEncoder().encode(preferences), to: "GamePresentation.json", createOnly: false, beforeCommit: { try execution.validate() })
        }
        return try snapshot(registry(prefix(record)), appID: appID, layout: selected, locked: false)
    }
}
