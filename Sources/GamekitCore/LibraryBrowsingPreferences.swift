import Foundation

public enum LibraryViewMode: String, Codable, Sendable { case grid, list }
public enum LibrarySortOrder: String, Codable, Sendable { case name, source, state, reportedSize }
public enum LibraryPreferencesError: Error, Equatable { case invalidDocument, invalidCoverSize, invalidFavorite }

public struct LibraryPreferencesSnapshot: Sendable {
    public let preferences: LibraryBrowsingPreferences
    public let savedPreferencesUnavailable: Bool
}

/// Browsing-only data. No startup destination is persisted: each window starts
/// at All Installed Games. A favorite is a stable installation ID, not a title.
public struct LibraryBrowsingPreferences: Codable, Equatable, Sendable {
    public var schemaVersion = 1
    public var viewMode: LibraryViewMode = .grid
    public var sortOrder: LibrarySortOrder = .name
    public var coverSize = 145
    public var sidebarVisible = true
    public var favorites: Set<SteamGameInstallationID> = []

    public init() {}

    func validate() throws {
        guard schemaVersion == 1, (125...220).contains(coverSize), favorites.count <= 512,
              favorites.allSatisfy({ $0.environmentID == SteamInstallationRecipe.environmentID && $0.appID > 0 })
        else { throw LibraryPreferencesError.invalidDocument }
    }

    /// Stale favorites stay saved for a later reinstall, but cannot produce a
    /// fabricated library tile when its installation is absent.
    public func favorites(in games: [SteamLibraryGame]) -> [SteamLibraryGame] {
        games.filter { favorites.contains($0.id) }
    }
}

/// Dedicated atomic/no-follow storage, independent of runtime/profile choices.
public actor LibraryPreferencesStore {
    private let root: URL
    private let filename = "LibraryBrowsing.json"

    public init(root: URL) { self.root = root }

    private func metadata(create: Bool) throws -> ManagedDirectory? {
        guard let root = try ManagedDirectory.openRoot(root, create: create) else { return nil }
        return try root.directory("Metadata", create: create)
    }

    private func read(_ directory: ManagedDirectory?) throws -> LibraryBrowsingPreferences {
        guard let bytes = try directory?.read(filename) else { return .init() }
        do {
            let settings = try JSONDecoder().decode(LibraryBrowsingPreferences.self, from: bytes)
            try settings.validate()
            return settings
        } catch { throw LibraryPreferencesError.invalidDocument }
    }

    /// A corrupt/unsupported document is reported without overwriting it. The
    /// caller may display defaults and a warning while keeping saved bytes intact.
    public func load() throws -> LibraryBrowsingPreferences { try read(metadata(create: false)) }

    public func loadForBrowsing() -> LibraryPreferencesSnapshot {
        do { return .init(preferences: try load(), savedPreferencesUnavailable: false) }
        catch { return .init(preferences: .init(), savedPreferencesUnavailable: true) }
    }

    private func update(_ change: (inout LibraryBrowsingPreferences) throws -> Void) throws -> LibraryBrowsingPreferences {
        guard let directory = try metadata(create: true) else { throw EnvironmentStoreError.notFound }
        return try directory.withWriteLock {
            var settings = try read(directory)
            try change(&settings)
            try settings.validate()
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try directory.write(encoder.encode(settings), to: filename, createOnly: false, beforeCommit: {})
            return settings
        }
    }

    @discardableResult public func setViewMode(_ mode: LibraryViewMode) throws -> LibraryBrowsingPreferences {
        try update { $0.viewMode = mode }
    }

    @discardableResult public func setSortOrder(_ order: LibrarySortOrder) throws -> LibraryBrowsingPreferences {
        try update { $0.sortOrder = order }
    }

    @discardableResult public func setCoverSize(_ size: Int) throws -> LibraryBrowsingPreferences {
        guard (125...220).contains(size) else { throw LibraryPreferencesError.invalidCoverSize }
        return try update { $0.coverSize = size }
    }

    @discardableResult public func setSidebarVisible(_ visible: Bool) throws -> LibraryBrowsingPreferences {
        try update { $0.sidebarVisible = visible }
    }

    @discardableResult public func setFavorite(_ id: SteamGameInstallationID, enabled: Bool) throws -> LibraryBrowsingPreferences {
        guard id.environmentID == SteamInstallationRecipe.environmentID, id.appID > 0 else {
            throw LibraryPreferencesError.invalidFavorite
        }
        return try update { preferences in
            if enabled { preferences.favorites.insert(id) }
            else { preferences.favorites.remove(id) }
        }
    }
}
