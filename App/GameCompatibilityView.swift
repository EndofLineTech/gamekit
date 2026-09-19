import GamekitCore
import SwiftUI

struct GameCompatibilityView: View {
    let game: InstalledSteamGame
    @EnvironmentObject private var setup: SetupModel
    @EnvironmentObject private var diagnostics: AppDiagnosticsModel
    @Environment(\.dismiss) private var dismiss
    @State private var snapshot: GameCompatibilitySnapshot?
    @State private var status = "Reading saved compatibility settings…"

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Compatibility · \(game.name)").font(.title2)
            Text("Graphics backend — shared by all games").font(.headline)
            GraphicsBackendPicker()
            Text("Steam passes this backend to every game in its managed environment. Change it while Steam is stopped; a fresh Steam session applies it.")
                .font(.caption).foregroundStyle(.secondary)
            if let problem = setup.problem { Text(problem).font(.callout).foregroundStyle(.secondary) }
            Divider()
            if GameCompatibilityStore.supports(game.id) {
                if let snapshot {
                    Text("Driver version compatibility — this game only").font(.headline)
                    Toggle("Avoid the virtual-GPU driver warning", isOn: Binding(
                        get: { snapshot.driverCompatibility },
                        set: { run(driver: $0) }))
                        .accessibilityIdentifier("game-driver-compatibility")
                        .disabled(setup.isBusy || snapshot.sessionLocked || !snapshot.driverCompatibilityAvailable || !setup.actions.reset)
                    Text(snapshot.driverCompatibilityAvailable
                         ? "Reports compatibility version 35.0.15.6094 to Helldivers instead of the invalid all-65535 value. This is not an actual driver update. Steam and other games are unaffected."
                         : "Requires the updated runtime. Choose Use updated runtime under Setup and prerequisites, then return to this game's settings.")
                        .font(.caption).foregroundStyle(.secondary)
                    Divider()
                    Text("Fullscreen display capture — this game only").font(.headline)
                    Text("Validated for Helldivers 2 to prevent Dock-edge cursor exposure. Select Fullscreen inside the game; this option does not change the game's resolution or create a macOS Space.")
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
                    Text("Select Fullscreen inside Helldivers. The optional Space keeps the full display area, including behind the notch, and closes when the game window closes. Changes apply at the next launch.")
                        .font(.caption)
                }
                Text("Stop Windows Steam and its games before changing settings. Restore capture default removes only the capture override; fullscreen presentation and the shared graphics backend are separate settings.")
                    .font(.caption).foregroundStyle(.secondary)
                Text(status).font(.callout).accessibilityIdentifier("game-compatibility-status")
                Button("Refresh saved settings") { run() }.disabled(setup.isBusy)
            } else {
                Text("No validated game-specific overrides are available for this title yet.")
            }
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(24).frame(width: 580)
        .task {
            while setup.isBusy && !Task.isCancelled { try? await Task.sleep(for: .milliseconds(100)) }
            if !Task.isCancelled && GameCompatibilityStore.supports(game.id) { run() }
        }
    }

    private func run(capture: GameCaptureOverride? = nil, space: Bool? = nil, driver: Bool? = nil) {
        guard let token = setup.begin(capture == nil && space == nil && driver == nil ? "Reading game compatibility" : "Saving game compatibility") else { return }
        Task {
            defer { setup.end(token); setup.refresh(diagnostics: diagnostics) }
            do {
                let settings = GameCompatibilityStore(store: try EnvironmentStore(root: AppStorageLocations.metadata))
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
                    snapshot = try await settings.inspect(appID: game.id)
                    status = snapshot?.sessionLocked == true ? "Stop Windows Steam to unlock changes, then refresh saved settings." : "Saved settings loaded."
                }
            } catch {
                snapshot = nil
                status = AppFailure.message(error)
            }
        }
    }
}
