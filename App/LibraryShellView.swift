import AppKit
import GamekitCore
import SwiftUI

private enum LibraryDestination: Hashable {
    case all, favorites, steam, ubisoft, settings
    var isLibrary: Bool { self == .all || self == .favorites || self == .steam || self == .ubisoft }
}

private enum LibraryInstallationFilter: String, CaseIterable {
    case all = "All installations", ready = "Ready to play", attention = "Needs attention"
}

private enum SettingsCategory: String, CaseIterable {
    case general = "General", gameDefaults = "Game defaults", launchers = "Launchers", storage = "Storage", diagnostics = "Diagnostics"
}

/// Native library-first shell over the existing window-owned Steam models.
/// Switching destinations never owns or restarts an installation/launch task.
struct LibraryShellView: View {
    @EnvironmentObject private var setup: SetupModel
    @EnvironmentObject private var diagnostics: AppDiagnosticsModel
    @EnvironmentObject private var games: InstalledGamesModel
    @EnvironmentObject private var steam: SteamLifecycleModel
    @EnvironmentObject private var ubisoft: UbisoftConnectModel
    @EnvironmentObject private var ubisoftGames: UbisoftCatalogModel
    @EnvironmentObject private var installation: SteamInstallationModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var destination: LibraryDestination = .all
    @State private var lastLibraryDestination: LibraryDestination = .all
    @State private var category: SettingsCategory = .general
    @State private var preferences = LibraryBrowsingPreferences()
    @State private var preferencesWarning = false
    @State private var settingsSidebarVisible = true
    @State private var wizardOffered = false
    @State private var showSetupWizard = false
    @State private var query = ""
    @State private var filter: LibraryInstallationFilter = .all
    @State private var selectedGameID: UInt32?
    @State private var selectedUbisoftID: UInt32?
    @State private var hoveredGameID: UInt32?
    @State private var hoveredUbisoftID: UInt32?
    @State private var inspectorVisible = false
    @State private var compatibilityGame: InstalledSteamGame?
    @State private var compatibilityRevision = 0
    @State private var uninstallGame: InstalledSteamGame?
    @State private var confirmingUninstall = false
    @FocusState private var searchFocused: Bool
    @FocusState private var focusedListID: UInt32?
    @FocusState private var focusedGameID: UInt32?
    private let preferenceStore = LibraryPreferencesStore(root: AppStorageLocations.metadata)
    private var sidebarAnimation: Animation? { reduceMotion ? nil : .easeInOut(duration: 0.28) }

    private var sidebarVisible: Bool { destination == .settings ? settingsSidebarVisible : preferences.sidebarVisible }
    private var librarySourceSummary: String {
        if destination == .ubisoft { return "Ubisoft Connect" }
        if destination == .all && ubisoft.installation == .installed { return "Windows Steam / Ubisoft Connect" }
        return "Windows Steam"
    }
    private var columnVisibility: Binding<NavigationSplitViewVisibility> {
        Binding(get: { sidebarVisible ? .all : .detailOnly }, set: { visibility in
            let visible = visibility != .detailOnly
            if destination == .settings { settingsSidebarVisible = visible }
            else if visible != preferences.sidebarVisible { setSidebar(visible) }
        })
    }

    private var selectedGame: InstalledSteamGame? { games.games.first { $0.id == selectedGameID } }
    private var selectedUbisoftGame: InstalledUbisoftGame? { ubisoftGames.games.first { $0.id == selectedUbisoftID } }

    private var visibleGames: [InstalledSteamGame] {
        guard destination != .ubisoft else { return [] }
        let matches = games.games.filter { game in
            (destination != .favorites || preferences.favorites.contains(.init(environmentID: SteamInstallationRecipe.environmentID, appID: game.id)))
                && (filter == .all || filter == .ready && game.state == .ready || filter == .attention && game.state != .ready)
                && (query.isEmpty || game.name.localizedStandardContains(query))
        }
        return preferences.sortOrder.sorted(matches)
    }

    private var visibleUbisoftGames: [InstalledUbisoftGame] {
        guard destination == .all || destination == .ubisoft else { return [] }
        let matches = ubisoftGames.games.filter { game in
            (filter == .all || filter == .ready && game.state == .installed || filter == .attention && game.state != .installed)
                && (query.isEmpty || game.name.localizedStandardContains(query))
        }
        return matches.sorted {
            if preferences.sortOrder == .state && $0.state != $1.state { return $0.state == .installed }
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
    }

    var body: some View {
        NavigationSplitView(columnVisibility: columnVisibility) {
            sidebar
                .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 260)
        } detail: {
            Group {
                if destination.isLibrary { libraryBody }
                else { settingsBody }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationSplitViewStyle(.balanced)
        .toolbar { windowToolbar }
        .searchable(text: $query, placement: .toolbar, prompt: "Search games")
        .searchFocused($searchFocused)
        .task {
            let restored = await preferenceStore.loadForBrowsing()
            preferences = restored.preferences
            preferencesWarning = restored.savedPreferencesUnavailable
        }
        .onReceive(NotificationCenter.default.publisher(for: .gamekitOpenSettings)) { _ in openSettings() }
        .onReceive(NotificationCenter.default.publisher(for: .gamekitOpenLauncherSetup)) { _ in openSettings(.launchers) }
        .onReceive(NotificationCenter.default.publisher(for: .gamekitOpenDiagnostics)) { _ in openSettings(.diagnostics) }
        .onReceive(NotificationCenter.default.publisher(for: .gamekitFocusSearch)) { _ in focusSearch() }
        .onChange(of: installation.installedSuccessfully) { _, completed in
            if completed {
                showSetupWizard = false
                if destination == .settings && category == .launchers { destination = .all }
            }
        }
        .onChange(of: setup.checkedAt) { _, _ in offerSetupWizard() }
        .onChange(of: setup.problem) { _, _ in offerSetupWizard() }
        .sheet(isPresented: $showSetupWizard) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Welcome to Gamekit")
                        .font(.largeTitle.bold()).accessibilityIdentifier("welcome-heading")
                    WelcomeSetupView(openLaunchers: {
                        showSetupWizard = false
                        NotificationCenter.default.post(name: .gamekitOpenLauncherSetup, object: nil)
                    }, browseLibrary: { showSetupWizard = false })
                }
                .padding(28)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minWidth: 650, idealWidth: 710, minHeight: 500, idealHeight: 640)
        }
        .onChange(of: destination) { _, current in
            if current.isLibrary { lastLibraryDestination = current }
        }
        .onExitCommand { dismissInspector() }
        .onChange(of: games.games) { _, current in
            if let selectedGameID, !current.contains(where: { $0.id == selectedGameID }), !games.libraryStale {
                self.selectedGameID = nil
            }
            if let focusedGameID, !current.contains(where: { $0.id == focusedGameID }), !games.libraryStale {
                self.focusedGameID = nil
            }
            if let focusedListID, !current.contains(where: { $0.id == focusedListID }), !games.libraryStale {
                self.focusedListID = nil
            }
        }
        .onChange(of: ubisoftGames.games) { _, current in
            if let selectedUbisoftID, !current.contains(where: { $0.id == selectedUbisoftID }), ubisoftGames.current {
                self.selectedUbisoftID = nil
            }
        }
        .onChange(of: preferences.viewMode) { _, mode in
            if let selectedGameID, visibleGames.contains(where: { $0.id == selectedGameID }) {
                if mode == .grid { focusedGameID = selectedGameID }
                else { focusedListID = selectedGameID }
            }
        }
        .onChange(of: selectedGameID) { _, id in
            if let id {
                inspectorVisible = true
                if preferences.viewMode == .list { focusedListID = id }
            }
        }
        .sheet(item: $compatibilityGame, onDismiss: { compatibilityRevision += 1 }) { GameCompatibilityView(game: $0) }
        .confirmationDialog("Uninstall \(uninstallGame?.name ?? "game")?", isPresented: $confirmingUninstall,
                            titleVisibility: .visible) {
            Button("Continue in Windows Steam", role: .destructive) {
                if let uninstallGame { games.uninstall(uninstallGame, setup: setup, diagnostics: diagnostics) }
                uninstallGame = nil
            }
            .help("Open this game's uninstall confirmation in Windows Steam")
            Button("Cancel", role: .cancel) { uninstallGame = nil }
                .help("Keep this game installed")
        } message: {
            Text("Windows Steam handles removal. Review and confirm it there; Gamekit refreshes the library afterward.")
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 5) {
            if destination == .settings {
                navButton("Back to Library", symbol: "chevron.left", active: false, identifier: "back-to-library") {
                    returnToLibrary()
                }
                sidebarHeading("Settings")
                ForEach(SettingsCategory.allCases, id: \.self) { option in
                    navButton(option.rawValue, symbol: option == .general ? "gearshape" : option == .launchers ? "square.stack" : option == .storage ? "externaldrive" : option == .diagnostics ? "waveform.path.ecg" : "gamecontroller",
                               active: category == option, identifier: "settings-\(option.rawValue)") { category = option }
                }
            } else {
                sidebarHeading("Library")
                navButton("All Installed Games", symbol: "square.grid.2x2", active: destination == .all, identifier: "library-all") { destination = .all }
                Button { destination = .favorites } label: {
                    sidebarRow("Favorites", active: destination == .favorites) {
                        Image(systemName: preferences.favorites.isEmpty ? "star" : "star.fill")
                            .symbolEffect(.bounce, value: preferences.favorites.count)
                            .accessibilityHidden(true)
                    }
                }
                .buttonStyle(.plain).accessibilityIdentifier("library-favorites")
                .help("Show your favorite games")
                if setup.record?.installation == .installed {
                    sidebarHeading("Launchers")
                    Button { destination = .steam } label: {
                        sidebarRow("Windows Steam", active: destination == .steam) { steamLauncherIcon }
                    }
                    .buttonStyle(.plain).accessibilityIdentifier("library-steam")
                    .help("Open Windows Steam games")
                }
                if ubisoft.installation == .installed {
                    Button { destination = .ubisoft } label: {
                        sidebarRow("Ubisoft Connect", active: destination == .ubisoft) {
                            ubisoftLauncherIcon
                        }
                    }
                    .buttonStyle(.plain).accessibilityIdentifier("library-ubisoft")
                    .help("Show games installed in managed Ubisoft Connect")
                }
                sidebarHeading("Management")
                navButton("Settings", symbol: "gearshape", active: false, identifier: "nav-settings") { openSettings() }
            }
            Spacer(minLength: 0)
            Text(steam.state == .running ? "Windows Steam running" : "Windows Steam · \(steam.state.rawValue)")
                .font(.caption).foregroundStyle(.secondary).padding(12)
        }
        .padding(.horizontal, 9)
    }

    private func sidebarHeading(_ title: String) -> some View {
        Text(title.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            .padding(.leading, 13).padding(.top, 15).padding(.bottom, 4)
    }

    private func navButton(_ title: String, symbol: String, active: Bool, identifier: String,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            sidebarRow(title, active: active) {
                Image(systemName: symbol).accessibilityHidden(true)
            }
        }
        .buttonStyle(.plain).accessibilityIdentifier(identifier)
        .help(title == "Back to Library" ? "Return to the previous library view" : "Open \(title)")
    }

    private func sidebarRow<Icon: View>(_ title: String, active: Bool, @ViewBuilder icon: () -> Icon) -> some View {
        HStack(spacing: 8) {
            icon().frame(width: 22, height: 22)
            Text(title)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(active ? LibraryVisualStyle.accent.opacity(0.18) : .clear,
                    in: RoundedRectangle(cornerRadius: 8))
    }

    private var steamLauncherIcon: some View {
        Image("SteamLauncherMark").resizable().frame(width: 16, height: 16)
            .frame(width: 22, height: 22)
            .background(.black.opacity(0.85), in: Circle())
            .accessibilityHidden(true)
    }

    private var ubisoftLauncherIcon: some View {
        Image("UbisoftLauncherMark").resizable().frame(width: 16, height: 16)
            .frame(width: 22, height: 22)
            .background(.black.opacity(0.85), in: Circle())
            .accessibilityHidden(true)
    }

    @ToolbarContentBuilder private var windowToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            if destination == .settings && !sidebarVisible {
                Button("Back to Library") { returnToLibrary() }
                    .accessibilityIdentifier("back-to-library")
                    .help("Return to the previous library view")
            }
            if destination.isLibrary {
                Button { setViewMode(.grid) } label: { Image(systemName: "square.grid.2x2") }
                    .accessibilityLabel("Box art view").accessibilityIdentifier("library-view-grid")
                    .tint(preferences.viewMode == .grid ? LibraryVisualStyle.accent : nil)
                    .help("Show games as box-art covers")
                Button { setViewMode(.list) } label: { Image(systemName: "list.bullet") }
                    .accessibilityLabel("List view").accessibilityIdentifier("library-view-list")
                    .tint(preferences.viewMode == .list ? LibraryVisualStyle.accent : nil)
                    .help("Show games in a sortable list")
                Button { inspectorVisible.toggle() } label: { Image(systemName: "info.circle") }
                    .accessibilityLabel("Toggle game inspector").accessibilityIdentifier("toggle-inspector")
                    .help(inspectorVisible ? "Hide game details" : "Show game details")
            }
        }
    }

    private var libraryBody: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(destination == .all ? "All Installed Games" : destination == .favorites ? "Favorites"
                                 : destination == .ubisoft ? "Ubisoft Connect" : "Windows Steam")
                                .font(.largeTitle.bold()).accessibilityIdentifier("library-heading")
                            Text("\(visibleGames.count + visibleUbisoftGames.count) installations · \(librarySourceSummary)")
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Refresh") { Task {
                            await games.refresh(setup: setup)
                            await ubisoftGames.refresh(setup: setup)
                        } }
                            // Background polling already coalesces in refresh(); toggling
                            // this button's disabled state every poll makes it flash.
                            .disabled(setup.isBusy).accessibilityIdentifier("refresh-games")
                            .help("Refresh installed games from managed launchers")
                    }
                    HStack(spacing: 8) {
                        ForEach(LibraryInstallationFilter.allCases, id: \.self) { choice in
                            Button(choice.rawValue) { filter = choice }
                                .buttonStyle(.bordered).tint(filter == choice ? LibraryVisualStyle.accent : nil)
                                .help("Filter library: \(choice.rawValue)")
                        }
                        Spacer(minLength: 8)
                        Picker("Sort", selection: Binding(get: { preferences.sortOrder }, set: { setSortOrder($0) })) {
                            Text("Name").tag(LibrarySortOrder.name)
                            Text("Launcher").tag(LibrarySortOrder.source)
                            Text("State").tag(LibrarySortOrder.state)
                            Text("Reported size").tag(LibrarySortOrder.reportedSize)
                        }
                        .frame(width: 160).accessibilityIdentifier("library-sort")
                        .help("Choose how installed games are sorted")
                    }
                    if preferences.viewMode == .grid {
                        HStack(spacing: 10) {
                            Text("Cover size").font(.caption).foregroundStyle(.secondary)
                            Slider(value: Binding(get: { Double(preferences.coverSize) },
                                                  set: { setCoverSize(Int($0)) }), in: 125...220)
                                .frame(width: 135).accessibilityIdentifier("library-cover-size")
                                .help("Adjust the size of box-art covers")
                            Spacer()
                        }
                    }
                    if preferencesWarning { Text("Saved library preferences could not be read; showing defaults. Your saved file was preserved.").foregroundStyle(.orange) }
                    if let warning = games.warning {
                        VStack(alignment: .leading, spacing: 8) {
                            Label(warning, systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.orange)
                            Button("View diagnostics") { diagnostics.open() }
                                .accessibilityIdentifier("library-diagnostics-link")
                                .help("Open local diagnostics for this library warning")
                        }
                    }
                    if destination == .all || destination == .ubisoft, let warning = ubisoftGames.warning {
                        Label(warning, systemImage: "info.circle").foregroundStyle(.secondary)
                            .accessibilityIdentifier("ubisoft-library-warning")
                    }
                    if (games.refreshing || ubisoftGames.refreshing) && games.games.isEmpty && ubisoftGames.games.isEmpty {
                        ProgressView("Reading installed games…")
                    } else if visibleGames.isEmpty && visibleUbisoftGames.isEmpty { emptyLibrary }
                    else {
                        if !visibleGames.isEmpty {
                            if preferences.viewMode == .grid {
                                coverGrid(width: geometry.size.width - 2 * LibraryVisualStyle.contentSpacing)
                            } else { gameList.frame(height: max(250, geometry.size.height - 220)) }
                        }
                        if !visibleUbisoftGames.isEmpty {
                            ubisoftLibrary(width: geometry.size.width - 2 * LibraryVisualStyle.contentSpacing)
                        }
                    }
                    if let message = games.message { Text(message).font(.callout).accessibilityIdentifier("game-launch-status") }
                    if let message = ubisoftGames.message { Text(message).font(.callout).accessibilityIdentifier("ubisoft-game-launch-status") }
                }
                .padding(LibraryVisualStyle.contentSpacing)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollEdgeEffectHidden(for: .top)
        }
        .inspector(isPresented: $inspectorVisible) {
            inspector.inspectorColumnWidth(min: 255, ideal: 290, max: 320)
        }
    }

    private func ubisoftLibrary(width: CGFloat) -> some View {
        let coverWidth = CGFloat(preferences.coverSize)
        let spacing: CGFloat = 18
        let columns = max(1, Int((max(width, coverWidth) + spacing) / (coverWidth + spacing)))
        return VStack(alignment: .leading, spacing: 12) {
            if destination == .all {
                Text("Ubisoft Connect").font(.title3.bold()).accessibilityIdentifier("ubisoft-library-heading")
            }
            if preferences.viewMode == .grid {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(coverWidth), spacing: spacing), count: columns),
                          alignment: .leading, spacing: 23) {
                    ForEach(visibleUbisoftGames) { game in ubisoftGameCard(game).frame(width: coverWidth) }
                }
            } else {
                ForEach(visibleUbisoftGames) { game in ubisoftGameRow(game) }
            }
        }
    }

    private func ubisoftGameCard(_ game: InstalledUbisoftGame) -> some View {
        let coverWidth = CGFloat(preferences.coverSize)
        return Button {
            selectedGameID = nil; selectedUbisoftID = game.id; inspectorVisible = true
        } label: {
            UbisoftGameTile(game: game, selected: selectedUbisoftID == game.id)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("select-ubisoft-game-\(game.id)")
        .help("Inspect \(game.name) from Ubisoft Connect")
        .overlay(alignment: .topTrailing) {
            if hoveredUbisoftID == game.id && game.state == .installed {
                Button { ubisoftGames.requestPlay(game, setup: setup) } label: {
                    Image(systemName: "play.fill").frame(width: 30, height: 30)
                }
                .buttonStyle(.glassProminent).buttonBorderShape(.circle)
                .tint(LibraryVisualStyle.accent)
                .disabled(!ubisoftGames.current || ubisoft.state != .running
                          || ubisoftGames.pendingGame != nil || setup.isBusy)
                .accessibilityLabel("Play \(game.name)")
                .accessibilityHint("Send one Play request through the verified Ubisoft Connect session; gameplay is not confirmed.")
                .accessibilityIdentifier("hover-launch-ubisoft-game-\(game.id)")
                .help(ubisoftGames.current && ubisoft.state == .running
                      ? "Request Play for \(game.name) through Ubisoft Connect"
                      : "Launch Ubisoft Connect to verify this game before Play")
                .padding(12)
                .frame(width: coverWidth, height: coverWidth * 1.5, alignment: .bottomTrailing)
            }
        }
        .onHover { hovering in
            if hovering { hoveredUbisoftID = game.id }
            else if hoveredUbisoftID == game.id { hoveredUbisoftID = nil }
        }
    }

    private func ubisoftGameRow(_ game: InstalledUbisoftGame) -> some View {
        Button {
            selectedGameID = nil; selectedUbisoftID = game.id; inspectorVisible = true
        } label: {
            HStack(spacing: 10) {
                UbisoftGameIcon(data: game.icon).frame(width: 32, height: 48)
                VStack(alignment: .leading, spacing: 3) {
                    Text(game.name).font(.headline)
                    Text("Ubisoft Connect · \(game.state == .installed ? "Installed" : "Installation incomplete")")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("select-ubisoft-game-\(game.id)")
        .accessibilityLabel("\(game.name), Ubisoft Connect, \(game.state == .installed ? "installed" : "incomplete"), size not reported")
        .help("Inspect \(game.name) from Ubisoft Connect")
    }

    private func coverGrid(width: CGFloat) -> some View {
        let spacing: CGFloat = 18
        let coverWidth = CGFloat(preferences.coverSize)
        let columnCount = max(1, Int((max(width, coverWidth) + spacing) / (coverWidth + spacing)))
        return ScrollViewReader { scroll in
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(coverWidth), spacing: spacing), count: columnCount),
                      alignment: .leading, spacing: 23) {
                ForEach(visibleGames) { game in
                    let favorite = isFavorite(game)
                    Button { select(game) } label: {
                        LibraryGridCell(game: game, selected: selectedGameID == game.id)
                            .frame(width: coverWidth)
                    }
                    .buttonStyle(.plain)
                    .focusable()
                    .focused($focusedGameID, equals: game.id)
                    .onKeyPress { press in
                        if (press.key == .return || press.key == .space),
                           press.modifiers.intersection([.command, .option, .control]).isEmpty {
                            select(game)
                            return .handled
                        }
                        return moveGridFocus(press.key, modifiers: press.modifiers, columns: columnCount)
                    }
                    .onKeyPress(.escape) { dismissInspector(); return .handled }
                    .accessibilityIdentifier("select-game-\(game.id)")
                    .accessibilityValue(favorite ? "Favorite" : "Not favorite")
                    .help("Select \(game.name); double-click to request Play")
                    .overlay(alignment: .topTrailing) {
                        if favorite || selectedGameID == game.id || hoveredGameID == game.id {
                            Button { toggleFavorite(game) } label: {
                                Image(systemName: favorite ? "star.fill" : "star")
                                    .foregroundStyle(.white).shadow(color: .black.opacity(0.8), radius: 3)
                                    .frame(width: 32, height: 32)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(favorite ? "Remove \(game.name) from Favorites" : "Add \(game.name) to Favorites")
                            .accessibilityIdentifier("favorite-game-\(game.id)")
                            .help(favorite ? "Remove \(game.name) from Favorites" : "Add \(game.name) to Favorites")
                            .padding(7)
                        }
                    }
                    .overlay(alignment: .topTrailing) {
                        if hoveredGameID == game.id && game.state == .ready {
                            let running = games.runningGames.contains(game.id)
                            Button { if running { stop(game) } else { play(game) } } label: {
                                Image(systemName: running ? "stop.fill" : "play.fill")
                                    .frame(width: 30, height: 30)
                            }
                            .buttonStyle(.glassProminent).buttonBorderShape(.circle)
                            .tint(LibraryVisualStyle.accent)
                            .disabled(games.pendingGame != nil || !games.gameObservationAvailable || games.libraryStale
                                      || setup.isBusy || (!running && !(setup.actions.launch || setup.actions.show)))
                            .accessibilityLabel("\(running ? "Stop" : "Play") \(game.name)")
                            .accessibilityHint(running ? "Stop this managed game without stopping Windows Steam or other games."
                                               : playHint(for: game))
                            .accessibilityIdentifier("\(running ? "hover-stop-game" : "hover-launch-game")-\(game.id)")
                            .help("\(running ? "Stop" : "Play") \(game.name)")
                            .padding(12)
                            .frame(width: coverWidth, height: coverWidth * 1.5, alignment: .bottomTrailing)
                        }
                    }
                    .simultaneousGesture(TapGesture(count: 2).onEnded { play(game) })
                    .contextMenu { gameMenu(game) }
                    .onHover { hovering in
                        if hovering { hoveredGameID = game.id }
                        else if hoveredGameID == game.id { hoveredGameID = nil }
                    }
                    .id(game.id)
                }
            }
            .onChange(of: focusedGameID) { _, id in
                if let id { scroll.scrollTo(id, anchor: .center) }
            }
        }
    }

    private func moveGridFocus(_ key: KeyEquivalent, modifiers: EventModifiers, columns: Int) -> KeyPress.Result {
        guard modifiers.intersection([.command, .option, .control]).isEmpty,
              let focused = focusedGameID, let index = visibleGames.firstIndex(where: { $0.id == focused }) else { return .ignored }
        let target: Int
        switch key {
        case .leftArrow: target = index - 1
        case .rightArrow: target = index + 1
        case .upArrow: target = index - columns
        case .downArrow: target = index + columns
        case .home: target = 0
        case .end: target = visibleGames.count - 1
        default: return .ignored
        }
        focusedGameID = visibleGames[min(max(target, 0), visibleGames.count - 1)].id
        return .handled
    }

    private var gameList: some View {
        Table(visibleGames, selection: $selectedGameID) {
            TableColumn("Game") { game in
                HStack(spacing: 8) {
                    Button { select(game) } label: {
                        HStack(spacing: 8) {
                            SteamPortraitCover(game: SteamLibraryGame(installed: game,
                                environmentID: SteamInstallationRecipe.environmentID), markSize: 14)
                                .frame(width: 32, height: 48).clipped()
                            Text(game.name).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .buttonStyle(.plain)
                    .focusable()
                    .focused($focusedListID, equals: game.id)
                    .onKeyPress { press in
                        if (press.key == .return || press.key == .space),
                           press.modifiers.intersection([.command, .option, .control]).isEmpty {
                            select(game)
                            return .handled
                        }
                        return moveListSelection(press.key, modifiers: press.modifiers)
                    }
                    .onKeyPress(.escape) { dismissInspector(); return .handled }
                    .accessibilityIdentifier("select-game-\(game.id)")
                    .accessibilityLabel("\(game.name), Windows Steam, \(status(game)), Steam-reported size: \(size(game))")
                    .accessibilityValue("\(selectedGameID == game.id ? "Selected" : "Not selected"), \(isFavorite(game) ? "favorite" : "not favorite")")
                    .help("Select \(game.name); double-click to request Play")
                    .simultaneousGesture(TapGesture(count: 2).onEnded { play(game) })
                    .contextMenu { gameMenu(game) }
                    Button { toggleFavorite(game) } label: {
                        Image(systemName: isFavorite(game) ? "star.fill" : "star")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(isFavorite(game) ? "Remove \(game.name) from Favorites" : "Add \(game.name) to Favorites")
                    .accessibilityIdentifier("favorite-game-\(game.id)")
                    .help(isFavorite(game) ? "Remove \(game.name) from Favorites" : "Add \(game.name) to Favorites")
                }
            }
            .width(min: 145, ideal: 175)
            TableColumn("Launcher") { _ in Text("Windows Steam").lineLimit(1) }
                .width(min: 90, ideal: 95)
            TableColumn("State") { game in Text(status(game)).lineLimit(1) }
                .width(min: 95, ideal: 105)
            TableColumn("Reported size") { game in Text(size(game)).lineLimit(1) }
                .width(min: 90, ideal: 95)
        }
        .accessibilityIdentifier("library-game-table")
    }

    private func moveListSelection(_ key: KeyEquivalent, modifiers: EventModifiers) -> KeyPress.Result {
        guard modifiers.intersection([.command, .option, .control]).isEmpty,
              let focused = focusedListID, let index = visibleGames.firstIndex(where: { $0.id == focused }) else { return .ignored }
        let target: Int
        switch key {
        case .upArrow: target = index - 1
        case .downArrow: target = index + 1
        case .home: target = 0
        case .end: target = visibleGames.count - 1
        default: return .ignored
        }
        select(visibleGames[min(max(target, 0), visibleGames.count - 1)])
        return .handled
    }

    private var emptyLibrary: some View {
        let initial = query.isEmpty && filter == .all
        let favoritesEmpty = initial && destination == .favorites
        let ubisoftEmpty = initial && destination == .ubisoft
        return LibraryPanel {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: "square.grid.2x2").font(.largeTitle).foregroundStyle(LibraryVisualStyle.accent)
                Text(favoritesEmpty ? "No favorites yet" : ubisoftEmpty ? "No Ubisoft games detected"
                     : initial ? "Your library starts here" : "No matching games")
                    .font(.title2.bold()).accessibilityIdentifier("games-empty")
                Text(favoritesEmpty ? "Mark a game as a favorite in your library."
                     : ubisoftEmpty ? "Launch Ubisoft Connect to verify installed games, then refresh this library."
                     : initial ? (setup.record?.installation == .installed
                         ? "Install games in Windows Steam to see them here."
                         : "Set up Windows Steam, then install a game to see it here.")
                     : "Try another search or clear the filters.")
                    .foregroundStyle(.secondary)
                Button(favoritesEmpty ? "Browse all games" : ubisoftEmpty ? "Manage Ubisoft Connect"
                       : initial && setup.record?.installation != .installed ? "Set up Gamekit" : initial ? "Manage Windows Steam" : "Clear filters") {
                    if favoritesEmpty { destination = .all }
                    else if initial && setup.record?.installation != .installed { showSetupWizard = true }
                    else if initial { openSettings(.launchers) }
                    else { query = ""; filter = .all }
                }
                .accessibilityIdentifier(initial && setup.record?.installation != .installed && !ubisoftEmpty ? "open-setup-wizard" : "empty-library-action")
            }
        }
    }

    private func offerSetupWizard() {
        #if DEBUG
        // Existing isolated UI fixtures exercise Settings and library navigation;
        // the two wizard fixtures explicitly opt into the first-run sheet.
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--metadata-root") && !arguments.contains("--ui-test-wizard") { return }
        #endif
        guard !wizardOffered, setup.checkedAt != nil || setup.problem != nil,
              setup.record?.installation != .installed, ubisoft.installation != .installed else { return }
        wizardOffered = true
        showSetupWizard = true
    }

    private var inspector: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 15) {
                if let game = selectedGame {
                    SteamPortraitCover(game: SteamLibraryGame(installed: game,
                        environmentID: SteamInstallationRecipe.environmentID))
                        .frame(width: 205, height: 308)
                    Text(game.name).font(.title2.bold())
                    Text("Windows Steam · \(status(game))").foregroundStyle(.secondary)
                    Text("Steam-reported size: \(size(game))").font(.callout)
                    HStack(spacing: 10) {
                        if games.runningGames.contains(game.id) {
                            Button { stop(game) } label: {
                                Image(systemName: "stop.fill").frame(width: 36, height: 30)
                            }
                            .buttonStyle(.glassProminent)
                            .disabled(games.pendingGame != nil || !games.gameObservationAvailable || games.libraryStale || setup.isBusy)
                            .accessibilityLabel("Stop \(game.name)")
                            .accessibilityHint("Stop this managed game without stopping Windows Steam or other games.")
                            .accessibilityIdentifier("stop-game-\(game.id)")
                            .help("Stop \(game.name)")
                        } else {
                            Button { play(game) } label: {
                                Image(systemName: "play.fill").frame(width: 36, height: 30)
                            }
                            .buttonStyle(.glassProminent)
                            .disabled(game.state != .ready || games.pendingGame != nil || !games.gameObservationAvailable
                                      || !(setup.actions.launch || setup.actions.show) || games.libraryStale)
                            .accessibilityLabel("Play \(game.name)")
                            .accessibilityIdentifier("launch-game-\(game.id)")
                            .accessibilityHint(playHint(for: game))
                            .help("Play \(game.name)")
                        }
                        Button { toggleFavorite(game) } label: {
                            Image(systemName: isFavorite(game) ? "star.fill" : "star").frame(width: 36, height: 30)
                        }
                        .buttonStyle(.bordered)
                        .accessibilityLabel(isFavorite(game) ? "Remove \(game.name) from Favorites" : "Add \(game.name) to Favorites")
                        .accessibilityIdentifier("inspector-favorite-game-\(game.id)")
                        .help(isFavorite(game) ? "Remove from Favorites" : "Add to Favorites")
                    }
                    LibraryInspectorSection(title: "Game actions") {
                        HStack(spacing: 10) {
                            Button { compatibilityGame = game } label: {
                                Image(systemName: "gearshape").frame(width: 36, height: 30)
                            }
                                .buttonStyle(.bordered)
                                .disabled(setup.isBusy)
                                .accessibilityIdentifier("game-compatibility-\(game.id)")
                                .accessibilityLabel("Compatibility settings for \(game.name)")
                                .help("All compatibility settings for \(game.name)")
                            Button { games.openGameFiles(game, setup: setup) } label: {
                                Image(systemName: "folder").frame(width: 36, height: 30)
                            }
                                .buttonStyle(.bordered)
                                .disabled(game.state != .ready || games.libraryStale || setup.isBusy)
                                .accessibilityIdentifier("game-files-\(game.id)")
                                .accessibilityLabel("Open \(game.name) files in Finder")
                                .help("Open this game's current managed installation folder in Finder")
                            Button { uninstallGame = game; confirmingUninstall = true } label: {
                                Image(systemName: "trash").frame(width: 36, height: 30)
                            }
                                .buttonStyle(.bordered)
                                .disabled(games.pendingGame != nil || games.libraryStale || !(setup.actions.launch || setup.actions.show))
                                .accessibilityIdentifier("uninstall-game-\(game.id)")
                                .accessibilityLabel("Uninstall \(game.name)")
                                .help("Uninstall \(game.name) through Windows Steam")
                        }
                    }
                    InspectorCompatibilitySummary(game: game, revision: compatibilityRevision)
                } else if let game = selectedUbisoftGame {
                    UbisoftPortraitCover(game: game)
                        .frame(width: 205, height: 308)
                    Text(game.name).font(.title2.bold())
                    Text("Ubisoft Connect · \(game.state == .installed ? "Installed" : "Installation incomplete")")
                        .foregroundStyle(.secondary)
                    Text("Ubisoft has not provided an installed-size figure for this entry.").font(.callout)
                    Button { ubisoftGames.requestPlay(game, setup: setup) } label: {
                        Label("Play \(game.name)", systemImage: "play.fill")
                    }
                    .buttonStyle(.glassProminent)
                    .disabled(game.state != .installed || !ubisoftGames.current || ubisoft.state != .running
                              || ubisoftGames.pendingGame != nil || setup.isBusy)
                    .accessibilityIdentifier("launch-ubisoft-game-\(game.id)")
                    .help("Request this installed game once through the managed Ubisoft Connect session")
                    Button(ubisoft.state == .running ? "Show Ubisoft Connect" : "Launch Ubisoft Connect") {
                        ubisoft.control(ubisoft.state == .running ? .show : .launch, setup: setup, diagnostics: diagnostics)
                    }
                    .disabled(setup.isBusy || ubisoft.state != .running && ubisoft.state != .stopped)
                    .accessibilityIdentifier("show-ubisoft-for-game")
                } else {
                    Text("Select a game").font(.title2.bold())
                    Text("Artwork, launch status and settings appear here.").foregroundStyle(.secondary)
                }
            }
            .padding(22).frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollEdgeEffectHidden(for: .top)
        .onExitCommand { dismissInspector() }
    }

    @ViewBuilder private func gameMenu(_ game: InstalledSteamGame) -> some View {
        if games.runningGames.contains(game.id) {
            Button("Stop \(game.name)") { stop(game) }
                .disabled(games.pendingGame != nil || !games.gameObservationAvailable || games.libraryStale || setup.isBusy)
                .help("Stop this game without stopping Windows Steam")
        } else if game.state == .ready {
            Button("Play") { play(game) }
                .disabled(games.pendingGame != nil || !games.gameObservationAvailable || games.libraryStale
                          || !(setup.actions.launch || setup.actions.show))
                .help("Request Play for \(game.name) through managed Windows Steam")
        }
        Button("Compatibility settings…") { compatibilityGame = game }
            .help("Open compatibility settings for \(game.name)")
        if game.state == .ready {
            Button("Open game files in Finder") { games.openGameFiles(game, setup: setup) }
                .disabled(games.libraryStale || setup.isBusy)
                .help("Reveal \(game.name)'s managed installation in Finder")
        }
        Button(isFavorite(game) ? "Remove Favorite" : "Add Favorite") { toggleFavorite(game) }
            .help(isFavorite(game) ? "Remove \(game.name) from Favorites" : "Add \(game.name) to Favorites")
        Divider()
        Button("Uninstall…") { uninstallGame = game; confirmingUninstall = true }
            .disabled(games.pendingGame != nil || games.libraryStale || !(setup.actions.launch || setup.actions.show))
            .help("Request uninstall of \(game.name) through Windows Steam")
    }

    private var settingsBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text(category.rawValue).font(.largeTitle.bold())
                    .accessibilityIdentifier(category == .diagnostics ? "diagnostics-heading" : "settings-heading")
                switch category {
                case .general:
                    LibraryPanel {
                        VStack(alignment: .leading, spacing: 14) {
                            Text("Open to All Installed Games").font(.headline)
                            Picker("Sort games by", selection: Binding(get: { preferences.sortOrder }, set: { setSortOrder($0) })) {
                                Text("Name").tag(LibrarySortOrder.name)
                                Text("Launcher").tag(LibrarySortOrder.source)
                                Text("State").tag(LibrarySortOrder.state)
                                Text("Reported size").tag(LibrarySortOrder.reportedSize)
                            }
                            .help("Set the saved game sort order")
                            Slider(value: Binding(get: { Double(preferences.coverSize) }, set: { setCoverSize(Int($0)) }), in: 125...220) {
                                Text("Cover size")
                            }
                            .help("Set the saved width of box-art covers")
                        }
                    }
                case .gameDefaults:
                    LibraryPanel {
                        VStack(alignment: .leading, spacing: 14) {
                            Text("Graphics backend for games using the shared default").font(.headline)
                            Text("Saved graphics backend: \(setup.layout.graphicsBackend.title)")
                                .accessibilityIdentifier("selected-graphics-backend")
                            GraphicsBackendPicker()
                            Text(setup.layout.graphicsBackend == .dxmt || setup.layout.graphicsBackend == .dxvk
                                 ? "Default for all games without an override. Windows Steam retains Metal 3. Direct3D 12 games need an Apple backend in their gear panel. Stop Windows Steam before changing settings."
                                 : "Applies to Windows Steam and all games using the shared default. Individual games can override it in their gear panel. Stop Windows Steam before changing it; the next Steam launch uses the saved choice.")
                                .font(.caption).accessibilityIdentifier("graphics-backend-scope")
                            Toggle("Shared fullscreen Space for games", isOn: Binding(
                                get: { setup.sharedFullscreenSpace },
                                set: { setup.chooseSharedFullscreenSpace($0, diagnostics: diagnostics) }))
                                .disabled(setup.isBusy || setup.selectionLocked)
                                .accessibilityIdentifier("shared-fullscreen-space")
                                .help("Use a separate macOS Space for eligible full-display games; per-game choices take precedence")
                            Text("Individual game overrides take precedence. Stop Windows Steam before changing defaults.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                case .launchers:
                    HStack(spacing: 10) {
                        steamLauncherIcon
                        Text("Windows Steam · Managed environment").foregroundStyle(.secondary)
                    }
                    if setup.record?.installation != .installed {
                        LibraryPanel {
                            VStack(alignment: .leading, spacing: 8) {
                                Label("Set up Windows Steam", systemImage: "square.and.arrow.down").font(.headline)
                                Text("Choose a validated runtime and complete the setup checks below. After installation, browse your managed library and install games in Windows Steam.")
                                    .foregroundStyle(.secondary)
                                Button("Install Wine") { setup.prepareWine(diagnostics: diagnostics) }
                                    .buttonStyle(.borderedProminent)
                                    .disabled(!setup.canPrepareWine)
                                    .accessibilityIdentifier("settings-install-wine")
                                if setup.winePrepared {
                                    Label("Wine is prepared and verified. Add Apple graphics to complete the runtime.", systemImage: "checkmark.circle.fill")
                                        .accessibilityIdentifier("settings-wine-prepared")
                                } else if setup.isReady {
                                    Text("The selected Wine runtime and graphics are already ready.")
                                        .font(.callout).foregroundStyle(.secondary)
                                } else {
                                    Text("Gamekit downloads and verifies Wine. No publisher links or manual Wine download are needed.")
                                        .font(.callout).foregroundStyle(.secondary)
                                }
                                if let status = setup.runtimeSetupStatus {
                                    Text(status).font(.callout).accessibilityIdentifier("settings-wine-status")
                                }
                                Button(setup.actions.retry ? "Retry Steam setup" : "Install Steam") {
                                    installation.start(diagnostics: diagnostics, setup: setup, recoveryRetry: setup.actions.retry)
                                }
                                .buttonStyle(.borderedProminent)
                                .disabled(installation.running || !(setup.actions.install || setup.actions.retry))
                                .accessibilityIdentifier("settings-quick-install-steam")
                                if !(setup.actions.install || setup.actions.retry), let reason = setup.steamInstallBlocker {
                                    Text(reason).font(.callout).foregroundStyle(.secondary)
                                        .accessibilityIdentifier("settings-quick-steam-blocker")
                                }
                                if let status = installation.status {
                                    Text(status).font(.callout).accessibilityIdentifier("settings-quick-steam-status")
                                }
                            }
                        }
                    }
                    SteamLifecycleView()
                    UbisoftConnectView()
                    if setup.record?.installation == .installed {
                        Button("Browse installed games") { destination = .steam }
                            .accessibilityIdentifier("browse-steam-games")
                            .help("Show games installed in managed Windows Steam")
                    }
                    SetupView()
                    SteamInstallationView()
                    EnvironmentSummaryView()
                case .storage:
                    LibraryPanel {
                        Button("Open steamapps folder") { games.openSteamapps(setup: setup) }
                            .disabled(setup.isBusy || setup.record?.installation != .installed)
                            .help("Open the managed Windows Steam library folder in Finder")
                        RecoveryArchivesView()
                        LauncherCachesView()
                    }
                case .diagnostics:
                    DiagnosticsView()
                    EnvironmentSummaryView()
                }
            }
            .padding(LibraryVisualStyle.contentSpacing)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollEdgeEffectHidden(for: .top)
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

    private func select(_ game: InstalledSteamGame) {
        selectedUbisoftID = nil
        selectedGameID = game.id
        if preferences.viewMode == .list { focusedListID = game.id }
        else { focusedGameID = game.id }
        inspectorVisible = true
    }

    private func dismissInspector() {
        inspectorVisible = false
        if let selectedGameID {
            if preferences.viewMode == .grid { focusedGameID = selectedGameID }
            else { focusedListID = selectedGameID }
        }
    }

    private func play(_ game: InstalledSteamGame) {
        guard !games.libraryStale else { return }
        games.launch(game, setup: setup, diagnostics: diagnostics)
    }

    private func stop(_ game: InstalledSteamGame) {
        games.stop(game, setup: setup, diagnostics: diagnostics)
    }

    private func playHint(for game: InstalledSteamGame) -> String {
        if games.libraryStale { return "The managed library is unreadable. Refresh its records before requesting Play." }
        if game.state != .ready { return "Finish this game's installation or update in Windows Steam first." }
        if !games.gameObservationAvailable { return "Managed game processes cannot be verified. Refresh before requesting Play." }
        if games.pendingGame != nil { return "Another game launch is being observed. Check Windows Steam before retrying." }
        if !(setup.actions.launch || setup.actions.show) { return "Complete Steam setup and runtime checks before requesting Play." }
        return "Request this game once through managed Windows Steam. A launch request does not prove gameplay readiness."
    }

    private func focusSearch() {
        destination = .all
        focusedGameID = nil
        focusedListID = nil
        searchFocused = true
        DispatchQueue.main.async {
            if let editor = NSApp.keyWindow?.firstResponder as? NSTextView, editor.isFieldEditor {
                editor.selectAll(nil)
            }
        }
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
            do {
                let saved = try await preferenceStore.setSidebarVisible(visible)
                withAnimation(sidebarAnimation) { preferences = saved }
                preferencesWarning = false
            }
            catch { preferencesWarning = true }
        }
    }

    private func returnToLibrary() {
        withAnimation(sidebarAnimation) { destination = lastLibraryDestination }
    }

    private func openSettings(_ requested: SettingsCategory? = nil) {
        if destination.isLibrary { lastLibraryDestination = destination }
        if let requested { category = requested }
        withAnimation(sidebarAnimation) {
            settingsSidebarVisible = true
            destination = .settings
        }
    }
}

/// One cancellable image decode per visible grid tile. The shared actor owns the
/// small data cache; scrolling never retains a decoded copy for every game.
private struct LibraryGridCell: View {
    @EnvironmentObject private var portraits: SteamPortraitModel
    let game: InstalledSteamGame
    let selected: Bool
    @State private var portrait: NSImage?

    var body: some View {
        LibraryGameTile(title: game.name, source: "Windows Steam", state: state,
                        needsAttention: game.state != .ready, reportedSize: reportedSize,
                        portrait: portrait, selected: selected, favorite: false,
                        mark: Image("SteamLauncherMark").resizable().frame(width: 25, height: 25))
            .task(id: game.id) {
                portrait = nil
                portrait = await portraits.image(for: .init(environmentID: SteamInstallationRecipe.environmentID,
                                                            appID: game.id))
            }
    }

    private var state: String {
        switch game.state {
        case .ready: "Installed"
        case .updating: "Updating or incomplete"
        case .missingFiles: "Missing files"
        }
    }

    private var reportedSize: String {
        game.sizeOnDiskBytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "Unavailable"
    }
}

/// Read-only effective settings alongside Play. The full sheet remains the
/// single editor, preserving inheritance, explicit overrides and session locks.
private struct InspectorCompatibilitySummary: View {
    let game: InstalledSteamGame
    let revision: Int
    @State private var graphics: GameGraphicsSnapshot?
    @State private var space: GameFullscreenSpaceSnapshot?
    @State private var unavailable = false

    var body: some View {
        LibraryInspectorSection(title: "Compatibility · next launch") {
            if let graphics, let space {
                Text("Graphics: \(graphics.effectiveBackend.title) · \(graphics.override == .inherit ? "shared default" : "game override")")
                    .accessibilityIdentifier("inspector-graphics-\(game.id)")
                Text("Fullscreen Space: \(space.effective ? "On" : "Off") · \(space.override == .inherit ? "inherited" : "game override")")
                    .accessibilityIdentifier("inspector-space-\(game.id)")
                Text(graphics.sessionLocked || space.sessionLocked
                     ? "Stop Windows Steam to change saved settings. They apply on the next launch."
                     : "Saved changes apply on the next launch, not to a game already running.")
                    .font(.caption).foregroundStyle(.secondary)
            } else if unavailable {
                Text("Per-game settings are unavailable. Open compatibility settings for details.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ProgressView("Loading saved settings…").controlSize(.small)
            }
        }
        .task(id: "\(game.id)-\(revision)") {
            graphics = nil; space = nil; unavailable = false
            do {
                let settings = GameCompatibilityStore(store: try EnvironmentStore(root: AppStorageLocations.metadata))
                let currentGraphics = try await settings.inspectGraphics(appID: game.id)
                let currentSpace = try await settings.inspectFullscreenSpace(appID: game.id)
                guard !Task.isCancelled else { return }
                graphics = currentGraphics; space = currentSpace
            } catch {
                guard !Task.isCancelled else { return }
                unavailable = true
            }
        }
    }
}
