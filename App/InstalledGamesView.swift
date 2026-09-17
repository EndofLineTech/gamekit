import AppKit
import GamekitCore
import SwiftUI

@MainActor
private final class InstalledGamesModel: ObservableObject {
    @Published private(set) var games: [InstalledSteamGame] = []
    @Published private(set) var refreshing = false
    @Published private(set) var warning: String?
    @Published private(set) var message: String?
    private var namesNeedRefresh = true

    func refresh(setup: SetupModel) async {
        guard !refreshing, !setup.isBusy else { return }
        refreshing = true
        defer { refreshing = false }
        do {
            let store = try EnvironmentStore(root: AppStorageLocations.metadata)
            guard let record = try await store.load(SteamInstallationRecipe.environmentID), record.installation == .installed else {
                games = []; warning = nil; return
            }
            let prefix = store.prefixURL(for: record.id)
            let result = try await Task.detached(priority: .utility) {
                try SteamGameLibrary.scan(prefix: prefix, steamExecutable: record.steamExecutable)
            }.value
            guard !setup.isBusy, !Task.isCancelled else { return }
            if games != result.games { games = result.games; namesNeedRefresh = true }
            warning = result.unreadableManifests == 0 ? nil :
                "\(result.unreadableManifests) Steam installation records could not be read. Let Steam finish its changes, then refresh."
            if namesNeedRefresh {
                do {
                    try await SteamLifecycle(store: store, layout: setup.layout).refreshGameNames()
                    namesNeedRefresh = false
                } catch EnvironmentStoreError.busy {
                    // A concurrent control operation owns the lease; the next poll retries.
                } catch {
                    warning = "Games were detected, but their Dock names could not be refreshed. Refresh after checking the managed Steam session."
                }
            }
        } catch {
            games = []
            warning = "The managed game library could not be read. Refresh after checking Steam and the environment."
        }
    }

    func launch(_ game: InstalledSteamGame, setup: SetupModel, diagnostics: AppDiagnosticsModel) {
        guard game.state == .ready, setup.actions.launch || setup.actions.show,
              let token = setup.begin("Launching \(game.name)") else { return }
        message = "Requesting \(game.name)…"
        Task { [self] in
            let operation = try? await diagnostics.store?.begin(stage: .launch, context: .init(component: .steam))
            do {
                let lifecycle = SteamLifecycle(store: try EnvironmentStore(root: AppStorageLocations.metadata), layout: setup.layout)
                try await lifecycle.launchGame(appID: game.id)
                message = "Launch requested for \(game.name). Steam handles first-run setup; check the game window."
                if let operation { _ = try? await diagnostics.store?.finish(operation, outcome: .exited(0)) }
            } catch {
                message = error as? SteamGameLibraryError == .notInstalled
                    ? "This game is no longer ready to launch. Check its installation in Windows Steam."
                    : AppFailure.message(error)
                if let operation { _ = try? await diagnostics.store?.finish(operation, outcome: .executionFailed) }
            }
            setup.end(token)
            await refresh(setup: setup)
            setup.refresh(diagnostics: diagnostics)
            diagnostics.refreshID = UUID()
        }
    }
}

struct InstalledGamesView: View {
    @EnvironmentObject private var setup: SetupModel
    @EnvironmentObject private var diagnostics: AppDiagnosticsModel
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var model = InstalledGamesModel()

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("Installed games", systemImage: "square.grid.2x2.fill").font(.headline)
                    Spacer()
                    Button("Refresh games", systemImage: "arrow.clockwise") {
                        Task { await model.refresh(setup: setup) }
                    }
                    .disabled(model.refreshing || setup.isBusy)
                    .accessibilityIdentifier("refresh-games")
                }
                if model.games.isEmpty {
                    Text("No games detected. Install a game in Windows Steam and it will appear here automatically.")
                        .foregroundStyle(.secondary).accessibilityIdentifier("games-empty")
                }
                ForEach(model.games) { game in
                    Button { model.launch(game, setup: setup, diagnostics: diagnostics) } label: {
                        HStack(spacing: 12) {
                            GameArtwork(game: game)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(game.name).font(.headline).lineLimit(2)
                                Text(status(game)).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "play.circle.fill").font(.title)
                        }
                        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                        .contentShape(RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                    .disabled(game.state != .ready || !(setup.actions.launch || setup.actions.show))
                    .accessibilityLabel("Launch \(game.name)")
                    .accessibilityValue(status(game))
                    .accessibilityIdentifier("launch-game-\(game.id)")
                    .help(game.state == .ready ? "Launch through managed Windows Steam" : "Finish installation or updates in Windows Steam")
                }
                if let warning = model.warning { Text(warning).font(.callout).foregroundStyle(.orange) }
                if let message = model.message { Text(message).font(.callout).accessibilityIdentifier("game-launch-status") }
                Text("Games in Gamekit's managed Steam library. External libraries are not shown. Launch starts Windows Steam if needed; installation does not establish game compatibility.")
                    .font(.caption).foregroundStyle(.secondary)
                if !model.games.isEmpty && !(setup.actions.launch || setup.actions.show) {
                    Text("Game launch is available when Steam setup and runtime checks are ready and no conflicting operation is active.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
        }
        .task(id: setup.selectionRevision) {
            while !Task.isCancelled {
                await model.refresh(setup: setup)
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await model.refresh(setup: setup) } }
        }
    }

    private func status(_ game: InstalledSteamGame) -> String {
        switch game.state {
        case .ready: "Installed · Launch"
        case .updating: "Installation or update incomplete · Open Steam"
        case .missingFiles: "Game files unavailable · Check Steam"
        }
    }
}

private struct GameArtwork: View {
    let game: InstalledSteamGame
    var body: some View {
        Group {
            if let data = game.artwork, let image = NSImage(data: data) {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                AsyncImage(url: URL(string: "https://cdn.akamai.steamstatic.com/steam/apps/\(game.id)/header.jpg")) { phase in
                    if let image = phase.image { image.resizable().scaledToFill() }
                    else { Image(systemName: "gamecontroller.fill").font(.largeTitle).foregroundStyle(.secondary) }
                }
            }
        }
        .frame(width: 100, height: 48).clipped()
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .accessibilityHidden(true)
    }
}
