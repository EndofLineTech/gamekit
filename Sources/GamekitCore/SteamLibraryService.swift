import Foundation

public struct SteamLibraryEntries: Sendable {
    public let games: [SteamLibraryGame]
    public let unreadableManifests: Int
    /// Existing Steam controls consume the scanned records during UI migration.
    /// This is in-memory only; presentation identities never encode local paths.
    public let installedGames: [InstalledSteamGame]
}

/// A Steam-only UI boundary. Execution remains with SteamLifecycle, including
/// its fresh manifest checks, runtime preflight, session ownership and leases.
public struct SteamLibraryService: Sendable {
    private let store: EnvironmentStore
    public let lifecycle: SteamLifecycle

    public init(store: EnvironmentStore, layout: RuntimeLayout) {
        self.store = store
        lifecycle = SteamLifecycle(store: store, layout: layout)
    }

    init(store: EnvironmentStore, lifecycle: SteamLifecycle) {
        self.store = store
        self.lifecycle = lifecycle
    }

    public func scan() async throws -> SteamLibraryEntries {
        guard let record = try await store.load(SteamInstallationRecipe.environmentID),
              record.installation == .installed else { throw SteamLifecycleError.notInstalled }
        let prefix = try await store.checkedPrefixURL(for: record.id)
        let snapshot = try SteamGameLibrary.scan(prefix: prefix, steamExecutable: record.steamExecutable)
        return .init(games: snapshot.games.map { SteamLibraryGame(installed: $0, environmentID: record.id) },
                     unreadableManifests: snapshot.unreadableManifests, installedGames: snapshot.games)
    }

    public func launch(_ id: SteamGameInstallationID) async throws -> SteamGameLaunchObservation {
        try validate(id)
        return try await lifecycle.launchGame(appID: id.appID)
    }

    /// The application must still present Steam's confirmation and bring its
    /// owned window forward after this request succeeds.
    public func requestUninstall(_ id: SteamGameInstallationID) async throws {
        try validate(id)
        try await lifecycle.requestGameUninstall(appID: id.appID)
    }

    /// The caller performs the existing SteamWindowPresentation focus handoff.
    public func openSteam() async throws {
        if try await lifecycle.status() == .running {
            try await lifecycle.show()
        } else {
            _ = try await lifecycle.launch()
        }
    }

    private func validate(_ id: SteamGameInstallationID) throws {
        guard id.environmentID == SteamInstallationRecipe.environmentID, id.appID > 0 else {
            throw SteamGameLibraryError.notInstalled
        }
    }
}
