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

    func start(diagnostics: AppDiagnosticsModel, verificationOnly: Bool = false) {
        guard task == nil else { return }
        running = true; confirmed = false; awaitingConfirmation = false
        status = "Checking prerequisites…"
        task = Task { [self] in
            defer {
                running = false; awaitingConfirmation = false; task = nil
                diagnostics.refreshID = UUID(); diagnostics.environmentRefreshID = UUID()
            }
            do {
                if coordinator == nil {
                    let store = try EnvironmentStore(root: AppStorageLocations.metadata)
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
                if verificationOnly {
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
}

struct SteamInstallationView: View {
    @EnvironmentObject private var diagnostics: AppDiagnosticsModel
    @StateObject private var model = SteamInstallationModel()
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
                Text("Recipe 1 · Sikarugir 10.0 revision 6 · D3DMetal 4.0b2")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(12)
        }
        .task {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--install-steam") { model.start(diagnostics: diagnostics) }
            if ProcessInfo.processInfo.arguments.contains("--verify-steam") { model.start(diagnostics: diagnostics, verificationOnly: true) }
            #endif
        }
    }
}
