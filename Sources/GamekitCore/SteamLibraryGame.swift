import Foundation

/// Identity for one Steam AppID in one managed environment. Titles and local
/// installation paths can change; this key can be used for selection/favorites.
public struct SteamGameInstallationID: Hashable, Codable, Sendable {
    public let environmentID: EnvironmentID
    public let appID: UInt32

    public init(environmentID: EnvironmentID, appID: UInt32) {
        self.environmentID = environmentID
        self.appID = appID
    }
}

/// Explicit presentation source; no execution or provider registration implied.
public enum LibraryGameSource: String, Codable, Sendable {
    case windowsSteam
}

/// Read-only library presentation over Steam's scanned records. Artwork is the
/// existing landscape header, not a portrait cover; portrait loading is separate.
public struct SteamLibraryGame: Identifiable, Equatable, Sendable {
    public let id: SteamGameInstallationID
    public let title: String
    public let source: LibraryGameSource
    public let state: SteamGameInstallState
    public let reportedSizeBytes: Int64?
    public let landscapeHeader: Data?

    public init(installed: InstalledSteamGame, environmentID: EnvironmentID) {
        id = SteamGameInstallationID(environmentID: environmentID, appID: installed.id)
        title = installed.name
        source = .windowsSteam
        state = installed.state
        reportedSizeBytes = installed.sizeOnDiskBytes
        landscapeHeader = installed.artwork
    }
}
