import AppKit
import GamekitCore
import SwiftUI

@MainActor
private final class InstalledGamesModel: ObservableObject {
    @Published private(set) var games: [InstalledSteamGame] = []
    @Published private(set) var refreshing = false
    @Published private(set) var warning: String?
    @Published private(set) var message: String?
    @Published private(set) var pendingGame: UInt32?
    private var launchObservation: Task<Void, Never>?
    private var namesNeedRefresh = true
    private var requestedUninstall: (id: UInt32, name: String)?

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
            if result.unreadableManifests == 0, let requested = requestedUninstall,
               !result.games.contains(where: { $0.id == requested.id }) {
                message = "\(requested.name) is no longer listed as installed in Windows Steam."
                requestedUninstall = nil
            }
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
        guard pendingGame == nil, game.state == .ready, setup.actions.launch || setup.actions.show,
              let token = setup.begin("Launching \(game.name)") else { return }
        message = "Requesting \(game.name)…"
        Task { [self] in
            let operation = try? await diagnostics.store?.begin(stage: .launch, context: .init(component: .steam))
            do {
                let lifecycle = SteamLifecycle(store: try EnvironmentStore(root: AppStorageLocations.metadata), layout: setup.layout)
                let observation = try await lifecycle.launchGame(appID: game.id)
                diagnostics.captureGameIfEnabled(game, layout: setup.layout)
                watch(observation, game: game)
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

    private func watch(_ observation: SteamGameLaunchObservation, game: InstalledSteamGame) {
        pendingGame = game.id
        message = "\(game.name): \(SteamGameLaunchProgress.waitingForSteam.message)"
        launchObservation = Task { [weak self] in
            guard let self else { return }
            defer { pendingGame = nil; launchObservation = nil }
            var progress = SteamGameLaunchProgress.waitingForSteam
            let deadline = ContinuousClock.now.advanced(by: .seconds(120))
            while !Task.isCancelled && ContinuousClock.now < deadline {
                progress = await observation.poll()
                message = "\(game.name): \(progress.message)"
                if progress.isTerminal { return }
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
            if [.cloudAttention, .otherSessionAttention, .userAttention].contains(progress) {
                message = "\(game.name): \(progress.message) Tracking has ended; check Steam before another Play request."
            } else {
                message = "Steam has not confirmed a new process for \(game.name). It may still be starting or already running. Check Windows Steam before trying Play again."
            }
        }
    }

    func uninstall(_ game: InstalledSteamGame, setup: SetupModel, diagnostics: AppDiagnosticsModel) {
        guard pendingGame == nil, setup.actions.launch || setup.actions.show,
              let token = setup.begin("Requesting uninstall for \(game.name)") else { return }
        message = "Opening uninstall for \(game.name) in Windows Steam…"
        Task { [self] in
            let operation = try? await diagnostics.store?.begin(stage: .uninstallation, context: .init(component: .steam))
            do {
                let lifecycle = SteamLifecycle(store: try EnvironmentStore(root: AppStorageLocations.metadata), layout: setup.layout)
                try await lifecycle.requestGameUninstall(appID: game.id)
                requestedUninstall = (game.id, game.name)
                message = "Uninstall requested for \(game.name). Confirm or cancel in Windows Steam; this list refreshes automatically."
                if let operation { _ = try? await diagnostics.store?.finish(operation, outcome: .exited(0)) }
            } catch {
                message = error as? SteamGameLibraryError == .notInstalled
                    ? "This game is no longer listed in the managed Steam library. Refresh games."
                    : AppFailure.message(error)
                if let operation { _ = try? await diagnostics.store?.finish(operation, outcome: .executionFailed) }
            }
            setup.end(token)
            await refresh(setup: setup)
            setup.refresh(diagnostics: diagnostics)
            diagnostics.refreshID = UUID()
        }
    }

    func openSteamapps(setup: SetupModel) {
        guard let token = setup.begin("Opening steamapps folder") else { return }
        Task {
            defer { setup.end(token) }
            do {
                let store = try EnvironmentStore(root: AppStorageLocations.metadata)
                guard let record = try await store.load(SteamInstallationRecipe.environmentID), record.installation == .installed else {
                    message = "Install Windows Steam before opening its steamapps folder."
                    return
                }
                let folder = store.prefixURL(for: record.id).appendingPathComponent(record.steamExecutable.rawValue)
                    .deletingLastPathComponent().appendingPathComponent("steamapps", isDirectory: true)
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                    message = "The managed steamapps folder is not available yet. Open Windows Steam to finish setup."
                    return
                }
                if !NSWorkspace.shared.open(folder) { message = "Finder could not open the managed steamapps folder." }
            } catch {
                message = AppFailure.message(error)
            }
        }
    }

    func showSteam(setup: SetupModel, diagnostics: AppDiagnosticsModel) {
        guard let token = setup.begin("Showing Windows Steam") else { return }
        Task {
            defer { setup.end(token); setup.refresh(diagnostics: diagnostics) }
            do {
                try await SteamLifecycle(store: EnvironmentStore(root: AppStorageLocations.metadata), layout: setup.layout).show()
            } catch { message = AppFailure.message(error) }
        }
    }
}

struct InstalledGamesView: View {
    @EnvironmentObject private var setup: SetupModel
    @EnvironmentObject private var diagnostics: AppDiagnosticsModel
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var model = InstalledGamesModel()
    @State private var compatibilityGame: InstalledSteamGame?
    @State private var uninstallGame: InstalledSteamGame?
    @State private var confirmUninstall = false

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("Installed games", systemImage: "square.grid.2x2.fill").font(.headline)
                    Spacer()
                    Button("Open steamapps folder", systemImage: "folder") { model.openSteamapps(setup: setup) }
                        .disabled(setup.isBusy || setup.record?.installation != .installed)
                        .accessibilityIdentifier("open-steamapps-folder")
                        .help("Open the managed Windows Steam library folder in Finder")
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
                    HStack(spacing: 8) {
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
                            .contentShape(RoundedRectangle(cornerRadius: 10))
                        }
                        .buttonStyle(.plain)
                        .disabled(model.pendingGame != nil || game.state != .ready || !(setup.actions.launch || setup.actions.show))
                        .accessibilityLabel("Launch \(game.name)")
                        .accessibilityValue(status(game))
                        .accessibilityIdentifier("launch-game-\(game.id)")
                        .help(game.state == .ready ? "Launch through managed Windows Steam" : "Finish installation or updates in Windows Steam")
                        Button { compatibilityGame = game } label: {
                            Image(systemName: "gearshape").font(.title2).frame(width: 40, height: 40)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(setup.isBusy)
                        .accessibilityLabel("Compatibility settings for \(game.name)")
                        .accessibilityIdentifier("game-compatibility-\(game.id)")
                        .help("Compatibility settings for \(game.name)")
                        Button {
                            uninstallGame = game
                            confirmUninstall = true
                        } label: {
                            Image(systemName: "trash").font(.title2).frame(width: 40, height: 40)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(model.pendingGame != nil || !(setup.actions.launch || setup.actions.show))
                        .accessibilityLabel("Uninstall \(game.name)")
                        .accessibilityIdentifier("uninstall-game-\(game.id)")
                        .help("Uninstall \(game.name) through managed Windows Steam")
                        .padding(.trailing, 10)
                    }
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                }
                if let warning = model.warning { Text(warning).font(.callout).foregroundStyle(.orange) }
                if let message = model.message {
                    Text(message).font(.callout).accessibilityIdentifier("game-launch-status")
                    Button("Show Windows Steam") { model.showSteam(setup: setup, diagnostics: diagnostics) }
                        .disabled(setup.isBusy || !setup.actions.show).accessibilityIdentifier("show-game-launch-steam")
                }
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
        .sheet(item: $compatibilityGame) { game in GameCompatibilityView(game: game) }
        .confirmationDialog("Uninstall \(uninstallGame?.name ?? "game")?", isPresented: $confirmUninstall, titleVisibility: .visible) {
            Button("Continue in Windows Steam", role: .destructive) {
                if let game = uninstallGame { model.uninstall(game, setup: setup, diagnostics: diagnostics) }
                uninstallGame = nil
            }
            .disabled(model.pendingGame != nil || !(setup.actions.launch || setup.actions.show))
            Button("Cancel", role: .cancel) { uninstallGame = nil }
        } message: {
            Text("Windows Steam will handle removal. Review and confirm it there. The installed-game list updates automatically.")
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
