import GamekitCore
import SwiftUI

struct GameCompatibilityView: View {
    let game: InstalledSteamGame
    @EnvironmentObject private var setup: SetupModel
    @EnvironmentObject private var diagnostics: AppDiagnosticsModel
    @Environment(\.dismiss) private var dismiss
    @State private var snapshot: GameCompatibilitySnapshot?
    @State private var graphics: GameGraphicsSnapshot?
    @State private var profile: ResolvedGameProfile?
    @State private var profileStatus: String?
    @State private var fetchingProfile = false
    @State private var status = "Reading saved compatibility settings…"

    var body: some View {
        ScrollView { settingsContent }
            .frame(maxHeight: 780)
            .task {
                profile = GameProfileStore.resolved(appID: game.id, root: AppStorageLocations.metadata)
                while setup.isBusy && !Task.isCancelled { try? await Task.sleep(for: .milliseconds(100)) }
                if !Task.isCancelled { run() }
                if (try? await GameProfileStore(root: AppStorageLocations.metadata).refresh(appID: game.id)) == true {
                    await refreshExecutionParameters()
                }
                if !Task.isCancelled {
                    profile = GameProfileStore.resolved(appID: game.id, root: AppStorageLocations.metadata)
                    if !setup.isBusy { run() }
                }
            }
    }

    private var settingsContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Compatibility · \(game.name)").font(.title2)
            if let profile {
                Text("Profile revision \(profile.profile.revision) · \(profile.source)").font(.caption)
                    .accessibilityIdentifier("game-profile-source")
                Text(profile.profile.notes).font(.caption)
            } else {
                Text("No matching profile cached. Existing defaults apply.").font(.caption)
            }
            HStack {
                Link("Profile JSON", destination: GameProfileStore.url(appID: game.id))
                Button("Update profile") {
                    fetchingProfile = true
                    Task {
                        defer { fetchingProfile = false }
                        do {
                            if try await GameProfileStore(root: AppStorageLocations.metadata).refresh(appID: game.id, force: true) {
                                await refreshExecutionParameters()
                            }
                            profile = GameProfileStore.resolved(appID: game.id, root: AppStorageLocations.metadata)
                            if !setup.isBusy { run() }
                            profileStatus = profile == nil ? "No published profile found." : "Profile checked. Applies to the next Gamekit Play request."
                        } catch { profileStatus = "Profile update unavailable. The last valid cached or bundled profile remains in use." }
                    }
                }.disabled(fetchingProfile)
            }.font(.caption)
            if let profileStatus { Text(profileStatus).font(.caption) }
            Text("Graphics backend — this game").font(.headline)
            if let graphics {
                GameGraphicsBackendPicker(selection: Binding(get: { graphics.override }, set: { run(backend: $0) }))
                    .disabled(setup.isBusy || graphics.sessionLocked || !setup.actions.reset)
                Text("Effective next launch: \(graphics.effectiveBackend.title)")
                    .accessibilityIdentifier("game-effective-backend")
                Text("Shared default: \(graphics.sharedBackend.title)").font(.caption)
                if let arguments = profile?.profile.arguments(for: graphics.effectiveBackend), !arguments.isEmpty {
                    Text("Gamekit Play applies these profile options for the selected backend. For launches directly from Steam, add these to its Launch Options:")
                        .font(.caption)
                    Text(arguments.joined(separator: " "))
                        .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                }
            }
            Text("Use shared default follows Setup. An override applies only to this game, including launches from managed Steam. DXMT and DXVK support Direct3D 10/11 only; choose an Apple backend for Direct3D 12 games. Steam keeps its Apple backend. Stop Windows Steam before changing settings.")
                .font(.caption).foregroundStyle(.secondary)
            if let problem = setup.problem { Text(problem).font(.callout).foregroundStyle(.secondary) }
            Divider()
            if let execution = profile?.profile.execution, execution.hasSettings {
                if let snapshot {
                    if let driver = execution.driver {
                    Text("Driver version compatibility — this game only").font(.headline)
                    Toggle("Avoid the virtual-GPU driver warning", isOn: Binding(
                        get: { snapshot.driverCompatibility },
                        set: { run(driver: $0) }))
                        .accessibilityIdentifier("game-driver-compatibility")
                        .disabled(setup.isBusy || snapshot.sessionLocked || !snapshot.driverCompatibilityAvailable || !setup.actions.reset)
                    Text(driver.guidance)
                        .font(.caption).foregroundStyle(.secondary)
                    Divider()
                    }
                    if let capture = execution.capture {
                    Text("Fullscreen display capture — this game only").font(.headline)
                    Text(capture.guidance)
                        .font(.caption)
                    Text("\(snapshot.capture.title) · Effective: \(snapshot.effectiveCapture ? "enabled" : "disabled")")
                        .accessibilityIdentifier("game-capture-setting")
                    Text("Inherited Wine setting: \(snapshot.inheritedCapture ? "enabled" : "disabled"). These are saved settings; changes apply at the next launch.").font(.caption)
                    HStack {
                        Button("Enable capture") { run(capture: .enabled) }.accessibilityIdentifier("enable-game-capture")
                        Button("Disable capture") { run(capture: .disabled) }.accessibilityIdentifier("disable-game-capture")
                        Button("Restore capture default") { run(capture: .inherit) }.accessibilityIdentifier("restore-game-defaults")
                    }
                    .disabled(setup.isBusy || snapshot.sessionLocked || !setup.actions.reset)
                    Divider()
                    }
                    if let space = execution.fullscreenSpace {
                    Text("Fullscreen presentation — this game only").font(.headline)
                    Text(snapshot.fullscreenSpace ? "Dedicated fullscreen Space" : "Fullscreen on the desktop")
                        .accessibilityIdentifier("game-fullscreen-presentation")
                    HStack {
                        Button("Use fullscreen Space") { run(space: true) }
                            .disabled(snapshot.fullscreenSpace).accessibilityIdentifier("enable-fullscreen-space")
                        Button("Use desktop fullscreen") { run(space: false) }
                            .disabled(!snapshot.fullscreenSpace).accessibilityIdentifier("disable-fullscreen-space")
                    }
                    .disabled(setup.isBusy || snapshot.sessionLocked || !setup.actions.reset)
                    Text(space.guidance)
                        .font(.caption)
                    }
                }
                Text("Stop Windows Steam and its games before changing settings. Restore capture default removes only the capture override; fullscreen presentation and the shared graphics backend are separate settings.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("No additional validated compatibility overrides are available for this title yet.")
            }
            Text(status).font(.callout).accessibilityIdentifier("game-compatibility-status")
            Button("Refresh saved settings") { run() }.disabled(setup.isBusy)
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(24).frame(width: 580)
    }

    private func run(capture: GameCaptureOverride? = nil, space: Bool? = nil, driver: Bool? = nil, backend: GameGraphicsOverride? = nil) {
        guard let token = setup.begin(capture == nil && space == nil && driver == nil && backend == nil ? "Reading game compatibility" : "Saving game compatibility") else { return }
        Task {
            defer { setup.end(token); setup.refresh(diagnostics: diagnostics) }
            do {
                let settings = GameCompatibilityStore(store: try EnvironmentStore(root: AppStorageLocations.metadata))
                if let backend {
                    graphics = try await settings.setGraphicsBackend(backend, appID: game.id)
                    status = "Saved and verified. Applies to this game's next launch."
                    return
                }
                graphics = try await settings.inspectGraphics(appID: game.id)
                if let driver {
                    snapshot = try await settings.setDriverCompatibility(driver, appID: game.id)
                    status = "Saved and verified. Applies when the game next launches."
                } else if let space {
                    snapshot = try await settings.setFullscreenSpace(space, appID: game.id)
                    status = "Saved and verified. Applies when the game next launches."
                } else if let capture {
                    snapshot = try await settings.setCapture(capture, appID: game.id)
                    status = "Saved and verified. Applies when the game next launches."
                } else {
                    if GameCompatibilityStore.supports(game.id, root: AppStorageLocations.metadata) { snapshot = try await settings.inspect(appID: game.id) }
                    status = graphics?.sessionLocked == true ? "Stop Windows Steam to unlock changes, then refresh saved settings." : "Saved settings loaded."
                }
            } catch {
                snapshot = nil
                status = AppFailure.message(error)
            }
        }
    }

    private func refreshExecutionParameters() async {
        guard !setup.isBusy, let store = try? EnvironmentStore(root: AppStorageLocations.metadata) else { return }
        try? await SteamLifecycle(store: store, layout: setup.layout).refreshGameNames()
    }
}
