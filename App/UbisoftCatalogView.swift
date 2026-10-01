import AppKit
import GamekitCore
import SwiftUI

@MainActor
final class UbisoftCatalogModel: ObservableObject {
    @Published private(set) var games: [InstalledUbisoftGame] = []
    @Published private(set) var refreshing = false
    @Published private(set) var current = false
    @Published private(set) var warning: String?
    @Published private(set) var message: String?
    @Published private(set) var pendingGame: UInt32?

    func refresh(setup: SetupModel) async {
        guard !refreshing, !setup.isBusy else { return }
        refreshing = true
        defer { refreshing = false }
        do {
            let service = try UbisoftGameCatalog(store: EnvironmentStore(root: AppStorageLocations.metadata),
                layout: setup.layout, profile: LauncherProfileStore.bundled("ubisoft"))
            let result = try await Task.detached(priority: .utility) { try await service.scan() }.value
            guard !Task.isCancelled else { return }
            games = result.games
            current = result.current && result.unreadableRecords == 0
            warning = result.unreadableRecords > 0
                ? "Some Ubisoft install records could not be verified. Last-known games are shown without Play."
                : result.current ? nil : result.games.isEmpty
                    ? "Launch Ubisoft Connect to discover installed games."
                    : "Launch Ubisoft Connect to verify these last-known games before Play."
        } catch {
            guard !Task.isCancelled else { return }
            current = false
            warning = "The Ubisoft game library could not be verified. Last-known entries are shown without Play."
        }
    }

    func requestPlay(_ game: InstalledUbisoftGame, setup: SetupModel) {
        guard pendingGame == nil, current, game.state == .installed,
              let token = setup.begin("Requesting \(game.name) through Ubisoft Connect") else { return }
        pendingGame = game.id
        message = "Requesting \(game.name) through Ubisoft Connect…"
        Task { [self] in
            defer { pendingGame = nil; setup.end(token) }
            do {
                let service = try UbisoftGameCatalog(store: EnvironmentStore(root: AppStorageLocations.metadata),
                    layout: setup.layout, profile: LauncherProfileStore.bundled("ubisoft"))
                try await service.requestPlay(game.id)
                message = "Sent one Play request for \(game.name). Check Ubisoft Connect; gameplay has not been confirmed."
            } catch {
                message = "Could not request \(game.name): \(AppFailure.message(error))"
            }
        }
    }
}

struct UbisoftGameIcon: View {
    let data: Data?

    var body: some View {
        Group {
            if let data, let image = NSImage(data: data) {
                Image(nsImage: image).resizable().scaledToFit()
            } else {
                Image(systemName: "gamecontroller.fill").resizable().scaledToFit().foregroundStyle(.secondary)
            }
        }
        .accessibilityHidden(true)
    }
}
