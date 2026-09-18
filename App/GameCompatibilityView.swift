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
            Text(setup.layout.graphicsBackend.title).accessibilityIdentifier("game-shared-backend")
            Text("Steam passes this backend to every game in its managed environment. Change it under Setup and prerequisites while Steam is stopped; a fresh Steam session applies it.")
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            if GameCompatibilityStore.supports(game.id) {
                Text("Fullscreen display capture — this game only").font(.headline)
                Text("Validated for Helldivers 2 to prevent Dock-edge cursor exposure. Select Fullscreen inside the game; this option does not change the game's resolution or create a macOS Space.")
                    .font(.caption)
                if let snapshot {
                    Text("\(snapshot.capture.title) · Effective: \(snapshot.effectiveCapture ? "enabled" : "disabled")")
                        .accessibilityIdentifier("game-capture-setting")
                    Text("Inherited Wine setting: \(snapshot.inheritedCapture ? "enabled" : "disabled"). These are saved settings; changes apply at the next launch.").font(.caption)
                    HStack {
                        Button("Enable capture") { run(capture: .enabled) }.accessibilityIdentifier("enable-game-capture")
                        Button("Disable capture") { run(capture: .disabled) }.accessibilityIdentifier("disable-game-capture")
                        Button("Restore per-game defaults") { run(capture: .inherit) }.accessibilityIdentifier("restore-game-defaults")
                    }
                    .disabled(setup.isBusy || snapshot.sessionLocked || !setup.actions.reset)
                }
                Text("Stop Windows Steam and its games before changing settings. Restoring defaults removes only this game's capture override; it preserves the shared graphics backend and other settings.")
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

    private func run(capture: GameCaptureOverride? = nil) {
        guard let token = setup.begin(capture == nil ? "Reading game compatibility" : "Saving game compatibility") else { return }
        Task {
            defer { setup.end(token); setup.refresh(diagnostics: diagnostics) }
            do {
                let settings = GameCompatibilityStore(store: try EnvironmentStore(root: AppStorageLocations.metadata))
                if let capture {
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
