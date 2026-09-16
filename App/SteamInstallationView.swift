import GamekitCore
import SwiftUI

@MainActor
private final class SteamInstallationModel: ObservableObject {
    @Published var status = "Install into Gamekit's dedicated steam environment."
    @Published var running = false
    @Published var awaitingConfirmation = false
    private var confirmed = false
    private var task: Task<Void, Never>?
    private var coordinator: SteamInstallationCoordinator?

    func start(diagnostics: AppDiagnosticsModel, verificationOnly: Bool = false, recoveryRetry: Bool = false) {
        guard task == nil else { return }
        running = true; confirmed = false; awaitingConfirmation = false
        status = "Checking prerequisites…"
        task = Task { [self] in
            defer {
                running = false; awaitingConfirmation = false; task = nil
                diagnostics.refreshID = UUID(); diagnostics.environmentRefreshID = UUID()
            }
            do {
                let store = try EnvironmentStore(root: AppStorageLocations.metadata)
                if coordinator == nil {
                    coordinator = SteamInstallationCoordinator(store: store, layout: RuntimeLayout(dataRoot: store.root),
                        acquisition: try SteamInstallerAcquisition(root: store.root), diagnostics: diagnostics.store)
                }
                guard let coordinator else { return }
                let onStage: @Sendable (InstallationStage) async -> Void = { [self] stage in await self.show(stage) }
                let confirm: @Sendable () async throws -> Bool = { [self] in
                    while await !self.confirmed {
                        try await Task.sleep(for: .milliseconds(100))
                    }
                    try Task.checkCancellation()
                    return await self.confirmed
                }
                if recoveryRetry {
                    let recovery = SteamRecovery(store: store, layout: RuntimeLayout(dataRoot: store.root))
                    switch try await recovery.prepareRetry() {
                    case .install: _ = try await coordinator.install(onStage: onStage, confirmUsableUI: confirm)
                    case .resumeInstaller: _ = try await coordinator.resumeInstaller(onStage: onStage, confirmUsableUI: confirm)
                    case .verifySteam: _ = try await coordinator.verifyExistingInstallation(onStage: onStage, confirmUsableUI: confirm)
                    case .alreadyInstalled: break
                    }
                } else if verificationOnly {
                    _ = try await coordinator.verifyExistingInstallation(onStage: onStage, confirmUsableUI: confirm)
                } else {
                    _ = try await coordinator.install(onStage: onStage, confirmUsableUI: confirm)
                }
                status = "Steam installation verified. Setup closed its Steam session."
            } catch is CancellationError {
                status = "Installation interrupted; existing files were preserved."
            } catch {
                if error as? SteamInstallationError == .steamNotObserved {
                    status = "Steam was no longer observable. Keep its window open until you confirm in Gamekit. Use Retry Steam verification to try again; existing files were preserved."
                } else {
                    status = "Installation could not complete: \(String(describing: error)). Existing files were preserved."
                }
            }
            if await coordinator?.diagnosticsUnavailable == true { diagnostics.recordingProblem = true }
        }
    }

    private func show(_ stage: InstallationStage) {
        switch stage {
        case .downloadingInstaller: status = "Downloading and validating Valve's installer…"
        case .creatingPrefix: status = "Creating the managed Wine prefix…"
        case .runningInstaller: status = "Complete the Steam installer wizard. Keep its default folder and uncheck Run Steam before Finish."
        case .bootstrappingSteam: status = "Steam is starting and updating. Waiting for its managed processes…"
        case .validatingInstallation:
            status = "Keep Steam open. Once its sign-in or Library window is usable, confirm below. Gamekit will close Steam for you after verification."
            awaitingConfirmation = true
        }
    }
    func confirm() { confirmed = true; awaitingConfirmation = false; status = "Verifying and finishing setup…" }
    func cancel() { task?.cancel(); status = "Stopping this installation's Wine processes…" }

    func recover(reset: Bool, diagnostics: AppDiagnosticsModel) {
        guard task == nil else { return }
        running = true
        status = reset ? "Checking ownership and archiving the environment while preserving downloads…" : "Stopping the interrupted setup's owned Wine processes…"
        task = Task { [self] in
            defer {
                running = false; task = nil
                diagnostics.refreshID = UUID(); diagnostics.environmentRefreshID = UUID()
            }
            let operation = try? await diagnostics.store?.begin(stage: reset ? .installation : .shutdown, context: .init(component: .application))
            do {
                let store = try EnvironmentStore(root: AppStorageLocations.metadata)
                let recovery = SteamRecovery(store: store, layout: RuntimeLayout(dataRoot: store.root))
                if reset {
                    _ = try await recovery.resetPreservingDownloads(confirmed: true)
                    status = "Reset prepared. Downloads are preserved in the archive. Click Retry interrupted install to restore them during fresh setup."
                } else {
                    try await recovery.stopInterruptedSetup(confirmed: true)
                    status = "Interrupted setup stopped. Retry can now inspect and resume the saved stage."
                }
                if let operation { _ = try? await diagnostics.store?.finish(operation, outcome: .exited(0)) }
            } catch {
                status = "Recovery could not complete: \(error). Files and recovery journals were preserved."
                if let operation { _ = try? await diagnostics.store?.finish(operation, outcome: .executionFailed) }
            }
        }
    }
}

struct SteamInstallationView: View {
    @EnvironmentObject private var diagnostics: AppDiagnosticsModel
    @StateObject private var model = SteamInstallationModel()
    @State private var confirmReset = false
    @State private var confirmStop = false
    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Label("Install Windows Steam", systemImage: "square.and.arrow.down").font(.headline)
                Text(model.status).accessibilityIdentifier("installation-status")
                HStack {
                    Button("Install Steam") { model.start(diagnostics: diagnostics) }
                        .disabled(model.running).accessibilityIdentifier("install-steam")
                    Button("Retry Steam verification") { model.start(diagnostics: diagnostics, verificationOnly: true) }
                        .disabled(model.running).accessibilityIdentifier("verify-steam")
                    if model.running { Button("Cancel installation") { model.cancel() } }
                    if model.awaitingConfirmation {
                        Button("Steam UI is usable — finish setup") { model.confirm() }
                            .accessibilityIdentifier("confirm-steam-ui")
                    }
                }
                HStack {
                    Button("Retry interrupted install") { model.start(diagnostics: diagnostics, recoveryRetry: true) }
                        .disabled(model.running).accessibilityIdentifier("retry-installation")
                    Button("Reset, preserve downloads…") { confirmReset = true }
                        .disabled(model.running).accessibilityIdentifier("reset-preserve-downloads")
                    Button("Force-stop interrupted setup…") { confirmStop = true }
                        .disabled(model.running)
                }
                Text("Recipe 1 · Sikarugir 10.0 revision 6 · D3DMetal 4.0b2")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(12)
        }
        .confirmationDialog("Reset Gamekit's steam environment?", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Archive environment and preserve downloads", role: .destructive) { model.recover(reset: true, diagnostics: diagnostics) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The old environment, settings and sign-in data stay in a private archive. Fresh setup restores steamapps and depotcache, including downloaded games. External libraries are left in place. Steam must be stopped first.")
        }
        .confirmationDialog("Force-stop interrupted setup?", isPresented: $confirmStop, titleVisibility: .visible) {
            Button("Force-stop this setup", role: .destructive) { model.recover(reset: false, diagnostics: diagnostics) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Closes the selected managed environment's interrupted Wine session. Its installation files and downloaded games are preserved. For an installed Steam session, use Stop Windows Steam instead.")
        }
        .task {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--install-steam") { model.start(diagnostics: diagnostics) }
            if ProcessInfo.processInfo.arguments.contains("--verify-steam") { model.start(diagnostics: diagnostics, verificationOnly: true) }
            #endif
        }
    }
}
