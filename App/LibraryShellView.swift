import AppKit
import GamekitCore
import SwiftUI

private enum LibraryDestination: Hashable {
    case all, favorites, steam, launchers, diagnostics, settings
    var isLibrary: Bool { self == .all || self == .favorites || self == .steam }
}

private enum LibraryInstallationFilter: String, CaseIterable {
    case all = "All installations", ready = "Ready to play", attention = "Needs attention"
}

private enum SettingsCategory: String, CaseIterable {
    case general = "General", gameDefaults = "Game defaults", runtime = "Runtime", storage = "Storage"
}

/// Native library-first shell over the existing window-owned Steam models.
/// Switching destinations never owns or restarts an installation/launch task.
struct LibraryShellView: View {
    @EnvironmentObject private var setup: SetupModel
    @EnvironmentObject private var diagnostics: AppDiagnosticsModel
    @EnvironmentObject private var games: InstalledGamesModel
    @EnvironmentObject private var steam: SteamLifecycleModel
    @State private var destination: LibraryDestination = .all
    @State private var category: SettingsCategory = .general
    @State private var preferences = LibraryBrowsingPreferences()
    @State private var preferencesWarning = false
    @State private var query = ""
    @State private var filter: LibraryInstallationFilter = .all
    @State private var selectedGameID: UInt32?
    @State private var inspectorVisible = false
    @State private var compatibilityGame: InstalledSteamGame?
    @State private var uninstallGame: InstalledSteamGame?
    @State private var confirmingUninstall = false
    @FocusState private var searchFocused: Bool
    private let preferenceStore = LibraryPreferencesStore(root: AppStorageLocations.metadata)

    private var selectedGame: InstalledSteamGame? { games.games.first { $0.id == selectedGameID } }

    private var visibleGames: [InstalledSteamGame] {
        let matches = games.games.filter { game in
            (destination != .favorites || preferences.favorites.contains(.init(environmentID: SteamInstallationRecipe.environmentID, appID: game.id)))
                && (filter == .all || filter == .ready && game.state == .ready || filter == .attention && game.state != .ready)
                && (query.isEmpty || game.name.localizedStandardContains(query))
        }
        return matches.sorted { lhs, rhs in
            switch preferences.sortOrder {
            case .name: break
            case .source: break // Only managed Windows Steam exists today.
            case .state:
                if lhs.state != rhs.state { return lhs.state.rawValue < rhs.state.rawValue }
            case .reportedSize:
                if lhs.sizeOnDiskBytes != rhs.sizeOnDiskBytes {
                    guard let first = lhs.sizeOnDiskBytes else { return false }
                    guard let second = rhs.sizeOnDiskBytes else { return true }
                    return first > second
                }
            }
            let title = lhs.name.localizedStandardCompare(rhs.name)
            return title == .orderedSame ? lhs.id < rhs.id : title == .orderedAscending
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            if preferences.sidebarVisible {
                sidebar.frame(width: 220)
                Divider()
            }
            VStack(spacing: 0) {
                toolbar
                Divider()
                if destination.isLibrary { libraryBody }
                else if destination == .launchers { launchersBody }
                else if destination == .diagnostics { diagnosticsBody }
                else { settingsBody }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(LibraryVisualStyle.canvas)
        .task {
            let restored = await preferenceStore.loadForBrowsing()
            preferences = restored.preferences
            preferencesWarning = restored.savedPreferencesUnavailable
        }
        .onReceive(NotificationCenter.default.publisher(for: .gamekitOpenSettings)) { _ in destination = .settings }
        .onChange(of: games.games) { _, current in
            if let selectedGameID, !current.contains(where: { $0.id == selectedGameID }), !games.libraryStale {
                self.selectedGameID = nil
            }
        }
        .sheet(item: $compatibilityGame) { GameCompatibilityView(game: $0) }
        .confirmationDialog("Uninstall \(uninstallGame?.name ?? "game")?", isPresented: $confirmingUninstall,
                            titleVisibility: .visible) {
            Button("Continue in Windows Steam", role: .destructive) {
                if let uninstallGame { games.uninstall(uninstallGame, setup: setup, diagnostics: diagnostics) }
                uninstallGame = nil
            }
            Button("Cancel", role: .cancel) { uninstallGame = nil }
        } message: {
            Text("Windows Steam handles removal. Review and confirm it there; Gamekit refreshes the library afterward.")
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 10) {
                Image(nsImage: NSApplication.shared.applicationIconImage).resizable().frame(width: 36, height: 36)
                    .accessibilityHidden(true)
                Text("Gamekit").font(.title3.bold())
            }
            .padding(.horizontal, 12).padding(.top, 20).padding(.bottom, 18)
            if destination == .settings {
                navButton("Back to Launchers", symbol: "chevron.left", active: false, identifier: "back-to-launchers") {
                    destination = .launchers
                }
                sidebarHeading("Settings")
                ForEach(SettingsCategory.allCases, id: \.self) { option in
                    navButton(option.rawValue, symbol: option == .general ? "gearshape" : option == .runtime ? "cpu" : option == .storage ? "externaldrive" : "gamecontroller",
                              active: category == option, identifier: "settings-\(option.rawValue)") { category = option }
                }
            } else {
                sidebarHeading("Library")
                navButton("All Installed Games", symbol: "square.grid.2x2", active: destination == .all, identifier: "library-all") { destination = .all }
                navButton("Favorites", symbol: "star", active: destination == .favorites, identifier: "library-favorites") { destination = .favorites }
                if setup.record?.installation == .installed {
                    sidebarHeading("Launchers")
                    navButton("Windows Steam", symbol: "gamecontroller", active: destination == .steam, identifier: "library-steam") { destination = .steam }
                }
                sidebarHeading("Management")
                navButton("Launchers", symbol: "square.stack", active: destination == .launchers, identifier: "nav-launchers") { destination = .launchers }
                navButton("Diagnostics", symbol: "waveform.path.ecg", active: destination == .diagnostics, identifier: "nav-diagnostics") { destination = .diagnostics }
                navButton("Settings…", symbol: "gearshape", active: false, identifier: "nav-settings") { destination = .settings }
            }
            Spacer(minLength: 0)
            Text(steam.state == .running ? "Windows Steam running" : "Windows Steam · \(steam.state.rawValue)")
                .font(.caption).foregroundStyle(.secondary).padding(12)
        }
        .padding(.horizontal, 9)
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    private func sidebarHeading(_ title: String) -> some View {
        Text(title.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            .padding(.leading, 13).padding(.top, 15).padding(.bottom, 4)
    }

    private func navButton(_ title: String, symbol: String, active: Bool, identifier: String,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol).frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12).padding(.vertical, 9)
                .background(active ? LibraryVisualStyle.accent.opacity(0.18) : .clear,
                            in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain).accessibilityIdentifier(identifier)
    }

    private var toolbar: some View {
        HStack(spacing: LibraryVisualStyle.controlSpacing) {
            Button { setSidebar(!preferences.sidebarVisible) } label: {
                Image(systemName: "sidebar.left").frame(width: 22)
            }
            .accessibilityLabel("Toggle sidebar").accessibilityIdentifier("toggle-sidebar")
            Text(destination.isLibrary ? "Library" : destination == .settings ? "Settings" : destination == .launchers ? "Launchers" : "Diagnostics")
                .font(.subheadline.weight(.semibold))
            Spacer(minLength: 8)
            if destination.isLibrary {
                TextField("Search games", text: $query).textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 230).focused($searchFocused).accessibilityIdentifier("library-search")
                Button { destination = .all; searchFocused = true } label: { Image(systemName: "magnifyingglass") }
                    .keyboardShortcut("f", modifiers: .command).accessibilityLabel("Search games")
                Picker("View", selection: Binding(get: { preferences.viewMode }, set: { setViewMode($0) })) {
                    Label("Box art", systemImage: "square.grid.2x2").tag(LibraryViewMode.grid)
                    Label("List", systemImage: "list.bullet").tag(LibraryViewMode.list)
                }
                .pickerStyle(.segmented).frame(width: 130).accessibilityIdentifier("library-view-mode")
                Button { inspectorVisible.toggle() } label: { Image(systemName: "info.circle") }
                    .accessibilityLabel("Toggle game inspector").accessibilityIdentifier("toggle-inspector")
            }
        }
        .padding(.horizontal, 22).frame(height: 58)
    }

    private var libraryBody: some View {
        HStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(destination == .all ? "All Installed Games" : destination == .favorites ? "Favorites" : "Windows Steam")
                                .font(.largeTitle.bold()).accessibilityIdentifier("library-heading")
                            Text("\(visibleGames.count) installations · Windows Steam")
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Refresh") { Task { await games.refresh(setup: setup) } }
                            .disabled(games.refreshing || setup.isBusy).accessibilityIdentifier("refresh-games")
                    }
                    HStack(spacing: 8) {
                        ForEach(LibraryInstallationFilter.allCases, id: \.self) { choice in
                            Button(choice.rawValue) { filter = choice }
                                .buttonStyle(.bordered).tint(filter == choice ? LibraryVisualStyle.accent : nil)
                        }
                        Spacer(minLength: 8)
                        Picker("Sort", selection: Binding(get: { preferences.sortOrder }, set: { setSortOrder($0) })) {
                            Text("Name").tag(LibrarySortOrder.name)
                            Text("Launcher").tag(LibrarySortOrder.source)
                            Text("State").tag(LibrarySortOrder.state)
                            Text("Reported size").tag(LibrarySortOrder.reportedSize)
                        }
                        .frame(width: 160).accessibilityIdentifier("library-sort")
                    }
                    if preferencesWarning { Text("Saved library preferences could not be read; showing defaults. Your saved file was preserved.").foregroundStyle(.orange) }
                    if let warning = games.warning { Text(warning).foregroundStyle(.orange) }
                    if games.refreshing && games.games.isEmpty { ProgressView("Reading installed games…") }
                    else if visibleGames.isEmpty { emptyLibrary }
                    else if preferences.viewMode == .grid { coverGrid }
                    else { gameList }
                    if let message = games.message { Text(message).font(.callout).accessibilityIdentifier("game-launch-status") }
                }
                .padding(LibraryVisualStyle.contentSpacing)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if inspectorVisible {
                Divider()
                inspector.frame(minWidth: 255, idealWidth: 290, maxWidth: 320)
            }
        }
    }

    private var coverGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: CGFloat(preferences.coverSize), maximum: CGFloat(preferences.coverSize + 20)), spacing: 18)], spacing: 23) {
            ForEach(visibleGames) { game in
                let favorite = isFavorite(game)
                Button { select(game) } label: {
                    LibraryGameTile(title: game.name, source: "Windows Steam", state: status(game),
                                    needsAttention: game.state != .ready, reportedSize: size(game), portrait: nil,
                                    selected: selectedGameID == game.id, favorite: false,
                                    mark: Image(systemName: "window.split.2x2"))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("select-game-\(game.id)")
                .accessibilityValue(favorite ? "Favorite" : "Not favorite")
                .overlay(alignment: .topTrailing) {
                    Button { toggleFavorite(game) } label: {
                        Image(systemName: favorite ? "star.fill" : "star")
                            .foregroundStyle(.white).shadow(color: .black.opacity(0.8), radius: 3)
                            .frame(width: 32, height: 32)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(favorite ? "Remove \(game.name) from Favorites" : "Add \(game.name) to Favorites")
                    .accessibilityIdentifier("favorite-game-\(game.id)")
                    .padding(7)
                }
                .simultaneousGesture(TapGesture(count: 2).onEnded { play(game) })
                .contextMenu { gameMenu(game) }
            }
        }
    }

    private var gameList: some View {
        LazyVStack(spacing: 4) {
            HStack {
                Text("Game").frame(maxWidth: .infinity, alignment: .leading)
                Text("Launcher").frame(width: 120, alignment: .leading)
                Text("State").frame(width: 125, alignment: .leading)
                Text("Reported size").frame(width: 115, alignment: .trailing)
            }
            .font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.horizontal, 12)
            ForEach(visibleGames) { game in
                Button { select(game) } label: {
                    HStack(spacing: 10) {
                        RoundedRectangle(cornerRadius: 4).fill(LibraryVisualStyle.accent.gradient)
                            .overlay(Image(systemName: "gamecontroller.fill").foregroundStyle(.white))
                            .frame(width: 32, height: 46)
                        Text(game.name).fontWeight(.medium).frame(maxWidth: .infinity, alignment: .leading)
                        Text("Windows Steam").frame(width: 120, alignment: .leading)
                        Text(status(game)).frame(width: 125, alignment: .leading)
                        Text(size(game)).frame(width: 115, alignment: .trailing)
                    }
                    .font(.callout).padding(.horizontal, 12).padding(.vertical, 5)
                    .background(selectedGameID == game.id ? LibraryVisualStyle.accent.opacity(0.19) : LibraryVisualStyle.panel,
                                in: RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain).accessibilityIdentifier("select-game-\(game.id)")
                .simultaneousGesture(TapGesture(count: 2).onEnded { play(game) })
                .contextMenu { gameMenu(game) }
            }
        }
    }

    private var emptyLibrary: some View {
        LibraryPanel {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: "square.grid.2x2").font(.largeTitle).foregroundStyle(LibraryVisualStyle.accent)
                Text(query.isEmpty && filter == .all && destination != .favorites ? "Your library starts here" : "No matching games")
                    .font(.title2.bold()).accessibilityIdentifier("games-empty")
                Text(query.isEmpty && filter == .all && destination != .favorites
                     ? "Install games in Windows Steam to see them here."
                     : "Try another search or clear the filters.")
                    .foregroundStyle(.secondary)
                Button(query.isEmpty && filter == .all && destination != .favorites ? "Open Launchers" : "Clear filters") {
                    if query.isEmpty && filter == .all && destination != .favorites { destination = .launchers }
                    else { query = ""; filter = .all }
                }
            }
        }
    }

    private var inspector: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 15) {
                if let game = selectedGame {
                    Text(game.name).font(.title2.bold())
                    Text("Windows Steam · \(status(game))").foregroundStyle(.secondary)
                    Text("Steam-reported size: \(size(game))").font(.callout)
                    Button("Play") { play(game) }
                        .buttonStyle(.borderedProminent)
                        .disabled(game.state != .ready || games.pendingGame != nil || !(setup.actions.launch || setup.actions.show) || games.libraryStale)
                        .accessibilityIdentifier("launch-game-\(game.id)")
                    Button(isFavorite(game) ? "Remove from Favorites" : "Add to Favorites") { toggleFavorite(game) }
                    LibraryInspectorSection(title: "Game actions") {
                        Button("Show Windows Steam") { steam.control(stop: false, diagnostics: diagnostics, setup: setup) }
                            .disabled(!(setup.actions.launch || setup.actions.show))
                        Button("All compatibility settings…") { compatibilityGame = game }
                            .disabled(setup.isBusy).accessibilityIdentifier("game-compatibility-\(game.id)")
                        Button("Uninstall…") { uninstallGame = game; confirmingUninstall = true }
                            .disabled(games.pendingGame != nil || games.libraryStale || !(setup.actions.launch || setup.actions.show))
                            .accessibilityIdentifier("uninstall-game-\(game.id)")
                    }
                } else {
                    Text("Select a game").font(.title2.bold())
                    Text("Artwork, launch status and settings appear here.").foregroundStyle(.secondary)
                }
            }
            .padding(22).frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(LibraryVisualStyle.panel)
    }

    @ViewBuilder private func gameMenu(_ game: InstalledSteamGame) -> some View {
        if game.state == .ready {
            Button("Play") { play(game) }.disabled(games.pendingGame != nil || games.libraryStale)
        }
        Button("Show Windows Steam") { steam.control(stop: false, diagnostics: diagnostics, setup: setup) }
        Button("Compatibility settings…") { compatibilityGame = game }
        Button(isFavorite(game) ? "Remove Favorite" : "Add Favorite") { toggleFavorite(game) }
        Divider()
        Button("Uninstall…") { uninstallGame = game; confirmingUninstall = true }
            .disabled(games.pendingGame != nil || games.libraryStale || !(setup.actions.launch || setup.actions.show))
    }

    private var launchersBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text("Launchers").font(.largeTitle.bold()).accessibilityIdentifier("launchers-heading")
                Text("Windows Steam · Managed environment").foregroundStyle(.secondary)
                SteamLifecycleView()
                Button("Browse installed games") { destination = .steam }
                    .accessibilityIdentifier("browse-steam-games")
                SetupView()
                SteamInstallationView()
                EnvironmentSummaryView()
            }
            .padding(LibraryVisualStyle.contentSpacing)
        }
    }

    private var diagnosticsBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text("Diagnostics").font(.largeTitle.bold()).accessibilityIdentifier("diagnostics-heading")
                DiagnosticsView()
            }.padding(LibraryVisualStyle.contentSpacing)
        }
    }

    private var settingsBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text(category.rawValue).font(.largeTitle.bold()).accessibilityIdentifier("settings-heading")
                switch category {
                case .general:
                    LibraryPanel {
                        VStack(alignment: .leading, spacing: 14) {
                            Text("Open to All Installed Games").font(.headline)
                            Picker("Default view", selection: Binding(get: { preferences.viewMode }, set: { setViewMode($0) })) {
                                Text("Box art").tag(LibraryViewMode.grid)
                                Text("List").tag(LibraryViewMode.list)
                            }
                            Picker("Sort games by", selection: Binding(get: { preferences.sortOrder }, set: { setSortOrder($0) })) {
                                Text("Name").tag(LibrarySortOrder.name)
                                Text("Launcher").tag(LibrarySortOrder.source)
                                Text("State").tag(LibrarySortOrder.state)
                                Text("Reported size").tag(LibrarySortOrder.reportedSize)
                            }
                            Slider(value: Binding(get: { Double(preferences.coverSize) }, set: { setCoverSize(Int($0)) }), in: 125...220) {
                                Text("Cover size")
                            }
                        }
                    }
                case .gameDefaults:
                    LibraryPanel {
                        VStack(alignment: .leading, spacing: 14) {
                            Text("Graphics backend for games using the shared default").font(.headline)
                            GraphicsBackendPicker()
                            Toggle("Shared fullscreen Space for games", isOn: Binding(
                                get: { setup.sharedFullscreenSpace },
                                set: { setup.chooseSharedFullscreenSpace($0, diagnostics: diagnostics) }))
                                .disabled(setup.isBusy || setup.selectionLocked)
                                .accessibilityIdentifier("shared-fullscreen-space")
                            Text("Individual game overrides take precedence. Stop Windows Steam before changing defaults.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                case .runtime:
                    SetupView()
                    EnvironmentSummaryView()
                case .storage:
                    LibraryPanel {
                        Button("Open steamapps folder") { games.openSteamapps(setup: setup) }
                            .disabled(setup.isBusy || setup.record?.installation != .installed)
                        RecoveryArchivesView()
                        LauncherCachesView()
                    }
                }
            }
            .padding(LibraryVisualStyle.contentSpacing)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func status(_ game: InstalledSteamGame) -> String {
        switch game.state {
        case .ready: "Installed"
        case .updating: "Updating or incomplete"
        case .missingFiles: "Missing files"
        }
    }

    private func size(_ game: InstalledSteamGame) -> String {
        guard let bytes = game.sizeOnDiskBytes else { return "Unavailable" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func isFavorite(_ game: InstalledSteamGame) -> Bool {
        preferences.favorites.contains(.init(environmentID: SteamInstallationRecipe.environmentID, appID: game.id))
    }

    private func select(_ game: InstalledSteamGame) { selectedGameID = game.id; inspectorVisible = true }

    private func play(_ game: InstalledSteamGame) {
        guard !games.libraryStale else { return }
        games.launch(game, setup: setup, diagnostics: diagnostics)
    }

    private func toggleFavorite(_ game: InstalledSteamGame) {
        let id = SteamGameInstallationID(environmentID: SteamInstallationRecipe.environmentID, appID: game.id)
        let enabled = !preferences.favorites.contains(id)
        Task {
            do { preferences = try await preferenceStore.setFavorite(id, enabled: enabled); preferencesWarning = false }
            catch { preferencesWarning = true }
        }
    }

    private func setViewMode(_ mode: LibraryViewMode) {
        Task {
            do { preferences = try await preferenceStore.setViewMode(mode); preferencesWarning = false }
            catch { preferencesWarning = true }
        }
    }

    private func setSortOrder(_ order: LibrarySortOrder) {
        Task {
            do { preferences = try await preferenceStore.setSortOrder(order); preferencesWarning = false }
            catch { preferencesWarning = true }
        }
    }

    private func setCoverSize(_ size: Int) {
        Task {
            do { preferences = try await preferenceStore.setCoverSize(size); preferencesWarning = false }
            catch { preferencesWarning = true }
        }
    }

    private func setSidebar(_ visible: Bool) {
        Task {
            do { preferences = try await preferenceStore.setSidebarVisible(visible); preferencesWarning = false }
            catch { preferencesWarning = true }
        }
    }
}
