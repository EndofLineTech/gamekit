import Foundation

/// Private, session-bound input for the Wine-side Dock identity helper. It
/// maps vetted copied Wine loaders, not arbitrary Windows launch commands, and
/// is never included in diagnostic exports.
struct GameDockNames: Codable {
    let schemaVersion: Int
    let prefix: String
    let sessionID: String
    let games: [String: String]
    let directories: [String: String]
    var loaders: [String: String] = [:]
    var defaultLoader: String? = nil
    var fullscreenSpaces: [String: Bool]? = nil
    var sharedGraphicsBackend: D3DMetalBackend? = nil
    var graphicsBackends: [String: GameGraphicsOverride]? = nil
    var defaultLibraryPath: String? = nil
    var dxvkLibraryPath: String? = nil
    var fullscreenExecutables: [String: String]? = nil

    static func url(root: URL, prefix: URL) -> URL {
        root.appendingPathComponent("Metadata/GameDock/\(prefix.lastPathComponent).json")
    }

    static func publish(root: URL, prefix: URL, session: UUID, games: [InstalledSteamGame],
                        steamExecutable: RelativePath = .steamDefault, loaders: [String: String] = [:],
                        defaultLoader: String? = nil, graphicsBackend: D3DMetalBackend = .automatic,
                        libraryLayout: RuntimeLayout? = nil, validate: () throws -> Void) throws {
        guard games.count <= 512 else { throw EnvironmentStoreError.documentTooLarge }
        let common = "c:\\" + steamExecutable.components.dropFirst().dropLast().joined(separator: "\\") + "\\steamapps\\common\\"
        let preferences = try GamePresentationPreferences.read(root: root)
        let compatibility = try GameCompatibilityPreferences.read(root: root)
        var spaces: [String: Bool] = [:], executables: [String: String] = [:]
        var driverParameters = ""
        for game in games where game.state == .ready {
            let key = String(game.id), parameters = gameExecution(appID: game.id, root: root)
            guard let executable = parameters.executable else { continue }
            if let space = parameters.fullscreenSpace {
                spaces[key] = preferences.fullscreenSpaces[key] ?? space.defaultEnabled
                executables[key] = executable
            }
            let backend = (compatibility.graphicsBackends[key] ?? .inherit).effectiveBackend(shared: graphicsBackend)
            if let layout = libraryLayout, let driver = parameters.driver, driver.backends.contains(backend),
               compatibility.driverEnabled(appID: game.id, revision: layout.profile.revision, root: root) {
                let directory = common + game.installDirectory + "\\"
                guard directory.rangeOfCharacter(from: .controlCharacters) == nil else { throw GameProfileError.invalid }
                driverParameters += "[\(key)]\nExecutable=\(executable)\nDirectory=\(directory)\nMatch=\(driver.matchHex)\nReplacement=\(driver.replacementHex)\n"
            }
        }
        let document = Self(schemaVersion: 1, prefix: prefix.path, sessionID: session.uuidString,
                            games: Dictionary(uniqueKeysWithValues: games.map { (String($0.id), $0.name) }),
                            directories: Dictionary(uniqueKeysWithValues: games.map { (String($0.id), common + $0.installDirectory + "\\") }),
                            loaders: loaders, defaultLoader: defaultLoader,
                             fullscreenSpaces: spaces,
                            sharedGraphicsBackend: graphicsBackend,
                            graphicsBackends: try GameCompatibilityPreferences.read(root: root).graphicsBackends.filter { key, choice in
                                choice != .inherit && games.contains { String($0.id) == key && $0.state == .ready }
                             }, defaultLibraryPath: libraryLayout?.defaultLibraryPath, dxvkLibraryPath: libraryLayout?.dxvkLibraryPath,
                             fullscreenExecutables: executables)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let bytes = try encoder.encode(document)
        guard let root = try ManagedDirectory.openRoot(root, create: true),
              let directory = try root.directory("Metadata", create: true)?.directory("GameDock", create: true)
        else { throw EnvironmentStoreError.notFound }
        try directory.withWriteLock {
            try validate()
            let name = prefix.lastPathComponent + ".json"
            // A bounded Win32-readable projection of the JSON parameters. The
            // generic PE adapter consumes this, never compiled game constants.
            let driverName = prefix.lastPathComponent + "-drivers.ini"
            let driverBytes = Data(([UInt8(0xff), 0xfe]) + Array(driverParameters.data(using: .utf16LittleEndian)!))
            if try directory.read(driverName) != driverBytes {
                try directory.write(driverBytes, to: driverName, createOnly: false, beforeCommit: validate)
            }
            if try directory.read(name) == bytes { return }
            try directory.write(bytes, to: name, createOnly: false, beforeCommit: validate)
        }
    }
}
