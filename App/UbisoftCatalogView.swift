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

@MainActor
final class UbisoftPortraitModel: ObservableObject {
    private let cache = try? UbisoftPortraitArtworkCache()

    func image(for id: UInt32) async -> NSImage? {
        guard let bytes = await cache?.portrait(for: id), !Task.isCancelled else { return nil }
        return NSImage(data: bytes)
    }
}

struct UbisoftCoverMark: View {
    var body: some View {
        Text("U").font(.system(size: 25, weight: .heavy, design: .rounded)).frame(width: 25, height: 25)
    }
}

struct UbisoftGameTile: View {
    @EnvironmentObject private var portraits: UbisoftPortraitModel
    let game: InstalledUbisoftGame
    let selected: Bool
    @State private var portrait: NSImage?

    var body: some View {
        LibraryGameTile(title: game.name, source: "Ubisoft Connect",
                        state: game.state == .installed ? "Installed" : "Installation incomplete",
                        needsAttention: game.state != .installed, reportedSize: "Size not reported",
                        portrait: portrait, selected: selected, favorite: false,
                        mark: UbisoftCoverMark(), fallbackIcon: game.icon.flatMap(NSImage.init(data:)),
                        sizeProvenance: "Installed size", preservePortrait: true)
            .task(id: game.id) {
                portrait = nil
                portrait = await portraits.image(for: game.id)
            }
    }
}

struct UbisoftPortraitCover: View {
    @EnvironmentObject private var portraits: UbisoftPortraitModel
    let game: InstalledUbisoftGame
    @State private var portrait: NSImage?

    var body: some View {
        LibraryCover(title: game.name, portrait: portrait, selected: false, favorite: false,
                     mark: UbisoftCoverMark(), fallbackIcon: game.icon.flatMap(NSImage.init(data:)),
                     preservePortrait: true)
            .task(id: game.id) {
                portrait = nil
                portrait = await portraits.image(for: game.id)
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
