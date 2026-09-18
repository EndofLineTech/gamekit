import GamekitCore
import SwiftUI

@MainActor
private final class SteamLifecycleModel: ObservableObject {
    @Published var state: SteamLifecycleState = .unverified
    @Published var busy = false
    @Published var message: String?
    private var lifecycle: SteamLifecycle?
    private var selectedBundle: URL?
    private var selectedRevision: RuntimeRevision?
    private var selectedBackend: D3DMetalBackend?
    private func controller(layout: RuntimeLayout) throws -> SteamLifecycle {
        if let lifecycle, selectedBundle == layout.bundle,
           selectedRevision == layout.profile.revision, selectedBackend == layout.graphicsBackend { return lifecycle }
        let store = try EnvironmentStore(root: AppStorageLocations.metadata)
        let created = SteamLifecycle(store: store, layout: layout)
        lifecycle = created
        selectedBundle = layout.bundle
        selectedRevision = layout.profile.revision
        selectedBackend = layout.graphicsBackend
        return created
    }
    func refresh(setup: SetupModel) async {
        guard !busy, !setup.isBusy else { return }
        do {
            let observed = try await controller(layout: setup.layout).status()
            guard !busy, !setup.isBusy else { return }
            state = observed
            await setup.refreshFacts(lifecycle: observed)
        } catch { state = .unverified; message = AppFailure.message(error) }
    }
    func control(stop: Bool, diagnostics: AppDiagnosticsModel, setup: SetupModel) {
        guard !busy, stop ? setup.actions.stop : (setup.actions.launch || setup.actions.show),
              let token = setup.begin(stop ? "Stopping Steam" : "Launching Steam") else { return }
        busy = true
        message = stop ? "Requesting shutdown; forced stop follows after 30 seconds if needed…" : "Starting managed Windows Steam…"
        Task { [self] in
            let operation = try? await diagnostics.store?.begin(stage: stop ? .shutdown : .launch, context: .init(component: .steam))
            do {
                if stop {
                    switch try await controller(layout: setup.layout).stop() {
                    case .alreadyStopped: message = "Steam was already stopped. Session ownership cleared."
                    case .graceful: message = "Steam stopped."
                    case .forced: message = "Steam stopped using the bounded fallback."
                    }
                }
                else {
                    if state == .running { try await controller(layout: setup.layout).show() }
                    else { _ = try await controller(layout: setup.layout).launch() }
                    message = "Steam window requested. Quitting Gamekit leaves Steam running."
                }
                if let operation { _ = try? await diagnostics.store?.finish(operation, outcome: .exited(0)) }
            } catch {
                message = AppFailure.message(error)
                if let operation { _ = try? await diagnostics.store?.finish(operation, outcome: .executionFailed) }
            }
            busy = false
            setup.end(token)
            await refresh(setup: setup)
            setup.refresh(diagnostics: diagnostics)
            diagnostics.refreshID = UUID(); diagnostics.environmentRefreshID = UUID()
        }
    }
}

struct SteamLifecycleView: View {
    @EnvironmentObject private var diagnostics: AppDiagnosticsModel
    @EnvironmentObject private var setup: SetupModel
    @StateObject private var model = SteamLifecycleModel()
    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Text("Steam: \(model.state.rawValue)").font(.headline).accessibilityIdentifier("lifecycle-state")
                if model.busy { ProgressView().controlSize(.small).accessibilityLabel("Steam operation in progress") }
                HStack {
                    Button(model.state == .running ? "Show Windows Steam" : "Launch Windows Steam") { model.control(stop: false, diagnostics: diagnostics, setup: setup) }
                        .disabled(model.busy || !(setup.actions.launch || setup.actions.show)).accessibilityIdentifier("launch-steam")
                        .keyboardShortcut("l", modifiers: .command)
                    Button("Stop Windows Steam") { model.control(stop: true, diagnostics: diagnostics, setup: setup) }
                        .disabled(model.busy || !setup.actions.stop).accessibilityIdentifier("stop-steam")
                        .keyboardShortcut("s", modifiers: [.command, .shift])
                }
                if let message = model.message { Text(message).font(.callout) }
                if model.state == .unverified { Text("Status is not verified. Refresh prerequisites and review the selected runtime before continuing.").font(.caption) }
                Text("Quit Gamekit to leave Steam and games running. Stop waits up to 30 seconds before forcing Steam and games in the managed environment to close.")
                    .font(.caption).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
        }
        .task(id: setup.selectionRevision) {
            await model.refresh(setup: setup)
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--launch-steam") {
                while (setup.report == nil || setup.isBusy) && setup.problem == nil && !Task.isCancelled { try? await Task.sleep(for: .milliseconds(100)) }
                if !Task.isCancelled {
                    await model.refresh(setup: setup)
                    model.control(stop: false, diagnostics: diagnostics, setup: setup)
                }
            }
            #endif
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                await model.refresh(setup: setup)
            }
        }
    }
}
