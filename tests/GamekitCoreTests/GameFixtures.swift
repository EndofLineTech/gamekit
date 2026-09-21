import Foundation

/// Shared by unit and UI tests. Game identities and expected settings are data.
enum GameFixtures {
    struct Game: Decodable, Sendable {
        let appId: UInt32
        let name: String
        let executable: String
        let probeExecutable: String?
        let matchVersion: [UInt16]?
        let replacementVersion: [UInt16]?
        let desktop: String?
        let size: String?
        let candidateSizes: [String]?
        let options: [String: String]?
        let launchArguments: [String: [String]]?
        func option(_ name: String) -> String { options![name]! }
        var replacementHex: String { replacementVersion!.map { String(format: "%04x", $0) }.joined() }
        var matchHex: String { matchVersion!.map { String(format: "%04x", $0) }.joined() }
        var manifest: Data {
            manifest(directory: name)
        }
        func manifest(directory: String) -> Data {
            Data("\"AppState\" { \"appid\" \"\(appId)\" \"name\" \"\(name)\" \"installdir\" \"\(directory)\" \"StateFlags\" \"4\" }".utf8)
        }
    }
    static let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("tests/fixtures/games.json")
    static func load(_ key: String) -> Game {
        let document = try! JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
        return try! JSONDecoder().decode(Game.self, from: JSONSerialization.data(withJSONObject: document[key]!))
    }
    static let primary = load("primary")
    static let renderer = load("renderer")
    static let desktop = load("legacyDesktop")
    static let other = load("other")
    static let trace = load("legacyTrace")
    struct Settings: Decodable, Sendable {
        let registry: String
        let syntheticDriverVersion: [Int]
    }
    static let settings: Settings = {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("fixtures/game-settings.json")
        return try! JSONDecoder().decode(Settings.self, from: Data(contentsOf: url))
    }()
    static var registry: String { settings.registry }
    static var syntheticVersion: [Int] { settings.syntheticDriverVersion }
    static var syntheticHex: String { syntheticVersion.map { String(format: "%04x", $0) }.joined() }
    static func preferences(game: Game, driver: Bool? = nil, backend: String? = nil, schema: Int = 2) throws -> Data {
        var value: [String: Any] = ["schemaVersion": schema,
            "driverVersions": driver.map { [String(game.appId): $0] } ?? [:]]
        if schema == 2 { value["graphicsBackends"] = backend.map { [String(game.appId): $0] } ?? [:] }
        return try JSONSerialization.data(withJSONObject: value)
    }
}
