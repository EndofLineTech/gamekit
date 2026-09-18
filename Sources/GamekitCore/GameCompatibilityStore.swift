import Foundation

public enum GameCompatibilityError: Error, Equatable { case unsupportedGame, unsupportedRegistry }
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
public struct GameCompatibilitySnapshot: Sendable {
    public let capture: GameCaptureOverride
    public let inheritedCapture: Bool
    public let graphicsBackend: D3DMetalBackend
    public let sessionLocked: Bool
    public var effectiveCapture: Bool { capture == .enabled || (capture == .inherit && inheritedCapture) }
}

/// Narrow, lossless edit of the two known Wine registry sections. The existing
/// prefix is the source of truth, so previously accepted settings are not reset
/// merely by opening Gamekit. No game configuration or binary is modified.
struct GameCaptureRegistry {
    private static let appSection = #"Software\\Wine\\AppDefaults\\helldivers2.exe\\Mac Driver"#
    private static let globalSection = #"Software\\Wine\\Mac Driver"#
    private static let key = "\"CaptureDisplaysForFullscreen\""
    private let lines: [String]
    init(_ data: Data) throws {
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
        get throws { try value(in: Self.appSection).map { $0.enabled ? .enabled : .disabled } ?? .inherit }
    }
    var inheritedCapture: Bool {
        get throws { try value(in: Self.globalSection)?.enabled ?? false }
    }
    func setting(_ setting: GameCaptureOverride) throws -> Data {
        _ = try inheritedCapture
        let previous = try value(in: Self.appSection)
        var edited = lines
        let line = Self.key + (setting == .enabled ? "=\"y\"" : "=\"n\"")
        if let previous {
            if setting == .inherit { edited.remove(at: previous.index) }
            else { edited[previous.index] = line }
        } else if setting != .inherit {
            if let range = try section(Self.appSection) { edited.insert(line, at: range.lowerBound + 1) }
            else { edited += ["", "[\(Self.appSection)]", line, ""] }
        }
        return Data(edited.joined(separator: "\n").utf8)
    }
}

public actor GameCompatibilityStore {
    private let store: EnvironmentStore
    private let observe: @Sendable (EnvironmentRecord, URL, RuntimeLayout) async -> RuntimeProcessSnapshot
    public static func supports(_ appID: UInt32) -> Bool { appID == 553850 }
    public init(store: EnvironmentStore) {
        self.store = store
        observe = { record, prefix, layout in await RuntimeProcessObserver().inspect(record: record, prefix: prefix, layout: layout) }
    }
    init(store: EnvironmentStore, observe: @escaping @Sendable (EnvironmentRecord, URL, RuntimeLayout) async -> RuntimeProcessSnapshot) {
        self.store = store; self.observe = observe
    }
    private func record(_ appID: UInt32) async throws -> EnvironmentRecord {
        guard Self.supports(appID) else { throw GameCompatibilityError.unsupportedGame }
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
    private func snapshot(_ data: Data, layout: RuntimeLayout, locked: Bool) throws -> GameCompatibilitySnapshot {
        let registry = try GameCaptureRegistry(data)
        return try .init(capture: registry.capture, inheritedCapture: registry.inheritedCapture,
                         graphicsBackend: layout.graphicsBackend, sessionLocked: locked)
    }
    public func inspect(appID: UInt32) async throws -> GameCompatibilitySnapshot {
        let installation = try await store.installationLease()
        defer { withExtendedLifetime(installation) {} }
        let record = try await record(appID)
        let settings = RuntimeSettingsStore(store: store)
        return try await snapshot(registry(prefix(record)), layout: settings.layout(), locked: settings.isSelectionLocked())
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
        for layout in [selected, RuntimeLayout(dataRoot: store.root), RuntimeLayout(dataRoot: store.root, profile: .sikarugirTextInput1)] {
            let observed = await observe(record, execution.prefix, layout)
            guard observed.complete else { throw SteamRecoveryError.observationUnavailable }
            guard observed.processes.isEmpty else { throw SteamRecoveryError.activeProcesses }
        }
        try execution.validate(); try Task.checkCancellation()
        let directory = try prefix(record)
        let original = try registry(directory)
        let updated = try GameCaptureRegistry(original).setting(capture)
        try directory.withWriteLock {
            try directory.write(updated, to: "user.reg", createOnly: false, temporaryPrefix: ".game-compatibility-", beforeCommit: {
                try execution.validate()
                guard try registry(directory) == original else { throw EnvironmentStoreError.conflict }
            })
        }
        let result = try snapshot(registry(directory), layout: selected, locked: false)
        guard result.capture == capture else { throw GameCompatibilityError.unsupportedRegistry }
        return result
    }
}
