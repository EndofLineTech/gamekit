import Foundation

public enum LauncherProfileError: Error, Equatable {
    case unsupportedSchema, invalidProfile
}

/// Bundled execution policy for one managed Windows launcher. A downloaded
/// catalog or a user-controlled game directory cannot change this policy.
public struct LauncherProfile: Codable, Equatable, Sendable {
    public struct Installer: Codable, Equatable, Sendable {
        public let url: URL
        public let sha256: String
        public let maximumBytes: Int
        public let arguments: [String]
    }
    public struct RuntimeModule: Codable, Equatable, Sendable {
        public let path: RelativePath
        public let originalSHA256: String
        public let replacementSHA256: String
        public let resource: String
    }
    public struct GameCatalog: Codable, Equatable, Sendable {
        public let installsRegistryKey: String
        public let uninstallRegistryKey: String
        public let uninstallKeyPrefix: String
        public let publisher: String
        public let gamesDirectory: RelativePath
        public let iconDirectory: RelativePath
        public let installMarkers: [String]
        public let launchURI: String
    }

    public let schemaVersion: Int
    public let id: EnvironmentID
    public let name: String
    public let installer: Installer
    public let executable: RelativePath
    public let clientExecutables: [String]
    public let webExecutables: [String]
    public let versionFile: RelativePath
    public let launchArguments: [String]?
    public let runtimeModule: RuntimeModule?
    public let gameCatalog: GameCatalog?

    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= 16_384 else { throw LauncherProfileError.invalidProfile }
        let profile = try JSONDecoder().decode(Self.self, from: data)
        try profile.validate()
        return profile
    }

    public func validate() throws {
        guard schemaVersion == 1 else { throw LauncherProfileError.unsupportedSchema }
        let url = URLComponents(url: installer.url, resolvingAgainstBaseURL: false)
        let directory = executable.components.dropLast()
        func validExecutableName(_ name: String) -> Bool {
            !name.isEmpty && name.count <= 128 && name.lowercased().hasSuffix(".exe") &&
                name.rangeOfCharacter(from: CharacterSet(charactersIn: "/\\:").union(.controlCharacters)) == nil
        }
        func validHash(_ hash: String) -> Bool {
            hash.count == 64 && hash.allSatisfy { "0123456789abcdef".contains($0) }
        }
        let moduleValid = runtimeModule.map { module in
            let path = module.path.components
            return path.count == 4 && path[0] == "lib" && path[1] == "wine" && path[2] == "x86_64-unix" &&
                path[3].hasSuffix(".so") && validHash(module.originalSHA256) &&
                validHash(module.replacementSHA256) && module.originalSHA256 != module.replacementSHA256 &&
                module.resource.range(of: "\\A[a-zA-Z0-9][a-zA-Z0-9._-]{0,127}\\.so\\z", options: .regularExpression) != nil
        } ?? true
        let catalogValid = gameCatalog.map { catalog in
            func registryKey(_ key: String, ending: String) -> Bool {
                key.hasPrefix("HKLM\\Software\\") && key.hasSuffix(ending) && key.count <= 256 &&
                    key.range(of: "\\A[A-Za-z0-9 _\\\\-]+\\z", options: .regularExpression) != nil
            }
            func marker(_ name: String) -> Bool {
                name.range(of: "\\A[A-Za-z0-9][A-Za-z0-9._-]{0,63}\\z", options: .regularExpression) != nil
            }
            let parent = Array(executable.components.dropLast())
            return registryKey(catalog.installsRegistryKey, ending: "\\Installs") &&
                registryKey(catalog.uninstallRegistryKey, ending: "\\Uninstall") &&
                catalog.uninstallKeyPrefix.range(of: "\\A[A-Za-z0-9 ]{1,48}\\z", options: .regularExpression) != nil &&
                !catalog.publisher.isEmpty && catalog.publisher.count <= 100 &&
                catalog.publisher.rangeOfCharacter(from: .controlCharacters) == nil &&
                catalog.gamesDirectory.components.starts(with: parent) &&
                catalog.gamesDirectory.components.count == parent.count + 1 &&
                catalog.iconDirectory.components.starts(with: parent) &&
                catalog.iconDirectory.components.count == parent.count + 1 &&
                (1...4).contains(catalog.installMarkers.count) &&
                Set(catalog.installMarkers).count == catalog.installMarkers.count &&
                catalog.installMarkers.allSatisfy(marker) &&
                catalog.launchURI.range(of: "\\A[a-z][a-z0-9+.-]{0,31}://launch/\\{id\\}(?:/[0-9]{1,3})?\\z",
                                        options: .regularExpression) != nil
        } ?? true
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              name.count <= 100, name != ".", name != "..",
              name.rangeOfCharacter(from: CharacterSet(charactersIn: "/\\:").union(.controlCharacters)) == nil,
              url?.scheme == "https", url?.host != nil, url?.user == nil, url?.password == nil,
              url?.port == nil || url?.port == 443, url?.query == nil, url?.fragment == nil,
              url?.percentEncodedPath.lowercased().hasSuffix(".exe") == true,
              (1...512 * 1024 * 1024).contains(installer.maximumBytes),
              installer.sha256.count == 64,
              installer.sha256.allSatisfy({ "0123456789abcdef".contains($0) }),
              installer.arguments.count <= 8,
              installer.arguments.allSatisfy({ !$0.isEmpty && $0.count <= 64 &&
                  $0.rangeOfCharacter(from: .controlCharacters) == nil }),
              (launchArguments?.count ?? 0) <= 8,
              launchArguments?.allSatisfy({ $0.range(of: "\\A--[a-z][a-z0-9-]{0,62}\\z", options: .regularExpression) != nil }) != false,
              moduleValid,
              catalogValid,
              executable.components.first == "drive_c", validExecutableName(executable.components.last ?? ""),
              versionFile.components.dropLast() == directory, versionFile.components.last == "version.txt",
              !clientExecutables.isEmpty, clientExecutables.count <= 8, webExecutables.count <= 8,
              (clientExecutables + webExecutables).allSatisfy(validExecutableName),
              Set((clientExecutables + webExecutables).map { $0.lowercased() }).count == clientExecutables.count + webExecutables.count
        else { throw LauncherProfileError.invalidProfile }
    }
}

public enum LauncherProfileStore {
    public static func bundled(_ name: String) throws -> LauncherProfile {
        guard name.range(of: "\\A[a-z0-9_-]{1,64}\\z", options: .regularExpression) != nil,
              let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "LauncherProfiles")
        else { throw LauncherProfileError.invalidProfile }
        let profile = try LauncherProfile.decode(Data(contentsOf: url))
        guard profile.id.rawValue == name else { throw LauncherProfileError.invalidProfile }
        return profile
    }
}
