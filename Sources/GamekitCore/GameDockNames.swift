import Foundation

/// Private, session-bound input for the Wine-side Dock identity helper. It
/// contains no launch commands and is never included in diagnostic exports.
struct GameDockNames: Codable {
    let schemaVersion: Int
    let prefix: String
    let sessionID: String
    let games: [String: String]

    static func url(root: URL, prefix: URL) -> URL {
        root.appendingPathComponent("Metadata/GameDock/\(prefix.lastPathComponent).json")
    }

    static func publish(root: URL, prefix: URL, session: UUID, games: [InstalledSteamGame], validate: () throws -> Void) throws {
        guard games.count <= 512 else { throw EnvironmentStoreError.documentTooLarge }
        let document = Self(schemaVersion: 1, prefix: prefix.path, sessionID: session.uuidString,
                            games: Dictionary(uniqueKeysWithValues: games.map { (String($0.id), $0.name) }))
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let bytes = try encoder.encode(document)
        guard let root = try ManagedDirectory.openRoot(root, create: true),
              let directory = try root.directory("Metadata", create: true)?.directory("GameDock", create: true)
        else { throw EnvironmentStoreError.notFound }
        try directory.withWriteLock {
            try validate()
            let name = prefix.lastPathComponent + ".json"
            if try directory.read(name) == bytes { return }
            try directory.write(bytes, to: name, createOnly: false, beforeCommit: validate)
        }
    }
}
