import Foundation

public enum SteamGameLibraryError: Error, Equatable { case invalidManifest, notInstalled }
public enum SteamGameInstallState: String, Sendable { case ready, updating, missingFiles }

public struct InstalledSteamGame: Identifiable, Equatable, Sendable {
    public let id: UInt32
    public let name: String
    public let installDirectory: String
    public let buildID: String?
    public let state: SteamGameInstallState
    public let artwork: Data?
}

public struct SteamGameLibrarySnapshot: Equatable, Sendable {
    public let games: [InstalledSteamGame]
    public let unreadableManifests: Int
}

/// A read-only view of the managed client's own steamapps directory. An ACF
/// receipt plus its common directory is installation evidence, not playability.
public enum SteamGameLibrary {
    public static func scan(prefix: URL, steamExecutable: RelativePath = .steamDefault) throws -> SteamGameLibrarySnapshot {
        let empty = SteamGameLibrarySnapshot(games: [], unreadableManifests: 0)
        guard var steam = try ManagedDirectory.openRoot(prefix, create: false) else { return empty }
        for component in steamExecutable.rawValue.split(separator: "/").dropLast() {
            guard let next = try steam.directory(String(component)) else { return empty }
            steam = next
        }
        guard let apps = try steam.directory("steamapps") else { return empty }
        let common = try apps.directory("common")
        let names = try apps.names().filter { $0.hasPrefix("appmanifest_") && $0.hasSuffix(".acf") }
        guard names.count <= 512 else { throw EnvironmentStoreError.documentTooLarge }
        let cache = try? steam.directory("appcache")?.directory("librarycache")
        var games: [InstalledSteamGame] = []
        var rejected = 0
        for filename in names {
            do {
                guard let data = try apps.read(filename),
                      let fields = try SteamKeyValues.parse(data)["appstate"]?.object,
                      let rawID = fields["appid"]?.string, let id = UInt32(rawID), id > 0,
                      filename == "appmanifest_\(id).acf",
                      let name = fields["name"]?.string, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      name.count <= 256, name.rangeOfCharacter(from: .controlCharacters) == nil,
                      let folder = fields["installdir"]?.string, !folder.isEmpty, folder != ".", folder != "..",
                      folder.rangeOfCharacter(from: CharacterSet(charactersIn: "/\\:").union(.controlCharacters)) == nil,
                      let rawFlags = fields["stateflags"]?.string, let flags = UInt32(rawFlags)
                else { throw SteamGameLibraryError.invalidManifest }
                // Steam installs shared redistributables as an app; it is not a game.
                if id == 228980 { continue }
                let filesExist = try common?.directory(folder) != nil
                let state: SteamGameInstallState = (flags == 4 || flags == 68)
                    ? (filesExist ? .ready : .missingFiles) : .updating
                // Prefer Steam's cache; no account files or arbitrary manifest URLs.
                let artwork = (try? cache?.directory(String(id))?.read("header.jpg", maximumBytes: 262_144))
                    ?? (try? cache?.read("\(id)_header.jpg", maximumBytes: 262_144))
                games.append(.init(id: id, name: name, installDirectory: folder, buildID: fields["buildid"]?.string, state: state, artwork: artwork))
            } catch { rejected += 1 }
        }
        return .init(games: games.sorted {
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }, unreadableManifests: rejected)
    }
}

/// The quoted KeyValues subset written by Steam's ACF manifests. Reject duplicate
/// keys, excessive nesting, malformed escapes and trailing tokens rather than
/// guessing which app or installation state Steam intended.
enum SteamKeyValues {
    indirect enum Value {
        case text(String), section([String: Value])
        var string: String? { if case let .text(value) = self { value } else { nil } }
        var object: [String: Value]? { if case let .section(value) = self { value } else { nil } }
    }
    static func parse(_ data: Data) throws -> [String: Value] {
        guard data.count <= 1_048_576, let text = String(data: data, encoding: .utf8), !text.utf8.contains(0) else {
            throw SteamGameLibraryError.invalidManifest
        }
        var parser = Parser(bytes: Array(text.utf8))
        return try parser.object(depth: 0)
    }
    private struct Parser {
        let bytes: [UInt8]
        var index = 0
        mutating func skipWhitespace() {
            while index < bytes.count {
                if [9, 10, 13, 32].contains(bytes[index]) { index += 1 }
                else if bytes[index] == 47, index + 1 < bytes.count, bytes[index + 1] == 47 {
                    while index < bytes.count && bytes[index] != 10 { index += 1 }
                } else { break }
            }
        }
        mutating func string() throws -> String {
            skipWhitespace()
            guard index < bytes.count, bytes[index] == 34 else { throw SteamGameLibraryError.invalidManifest }
            index += 1
            var result: [UInt8] = []
            while index < bytes.count {
                let byte = bytes[index]; index += 1
                if byte == 34 {
                    guard let value = String(bytes: result, encoding: .utf8) else { throw SteamGameLibraryError.invalidManifest }
                    return value
                }
                if byte == 92 {
                    guard index < bytes.count else { throw SteamGameLibraryError.invalidManifest }
                    let escaped = bytes[index]; index += 1
                    switch escaped {
                    case 34, 92: result.append(escaped)
                    case 110: result.append(10)
                    case 114: result.append(13)
                    case 116: result.append(9)
                    default: throw SteamGameLibraryError.invalidManifest
                    }
                } else { result.append(byte) }
            }
            throw SteamGameLibraryError.invalidManifest
        }
        mutating func object(depth: Int) throws -> [String: Value] {
            guard depth <= 16 else { throw SteamGameLibraryError.invalidManifest }
            var result: [String: Value] = [:]
            while true {
                skipWhitespace()
                if index == bytes.count {
                    guard depth == 0 else { throw SteamGameLibraryError.invalidManifest }
                    return result
                }
                if bytes[index] == 125 {
                    guard depth > 0 else { throw SteamGameLibraryError.invalidManifest }
                    index += 1; return result
                }
                let key = try string().lowercased()
                guard result[key] == nil else { throw SteamGameLibraryError.invalidManifest }
                skipWhitespace()
                if index < bytes.count, bytes[index] == 123 {
                    index += 1; result[key] = .section(try object(depth: depth + 1))
                } else { result[key] = .text(try string()) }
            }
        }
    }
}
