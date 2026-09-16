import GamekitCore
import SwiftUI

@MainActor
private final class SteamLifecycleModel: ObservableObject {
    @Published var state: SteamLifecycleState = .unverified
    @Published var busy = false
    @Published var message: String?
    private var lifecycle: SteamLifecycle?
    private func controller() throws -> SteamLifecycle {
        if let lifecycle { return lifecycle }
        let store = try EnvironmentStore(root: AppStorageLocations.metadata)
        let created = SteamLifecycle(store: store, layout: RuntimeLayout(dataRoot: store.root))
        lifecycle = created
        return created
    }
    func refresh() async {
        guard !busy else { return }
        do { state = try await controller().status() }
        catch { state = .unverified; message = "Steam status unavailable: \(error)" }
    }
    func control(stop: Bool, diagnostics: AppDiagnosticsModel) {
        guard !busy else { return }
        busy = true
        message = stop ? "Requesting shutdown; forced stop follows after 30 seconds if needed…" : "Starting managed Windows Steam…"
        Task { [self] in
            let operation = try? await diagnostics.store?.begin(stage: stop ? .shutdown : .launch, context: .init(component: .steam))
            do {
                if stop { message = "Stopped: \(try await controller().stop().rawValue)." }
                else { _ = try await controller().launch(); message = "Launch requested. Quitting Gamekit leaves Steam running." }
                if let operation { _ = try? await diagnostics.store?.finish(operation, outcome: .exited(0)) }
            } catch {
                message = "Steam control failed: \(error)"
                if let operation { _ = try? await diagnostics.store?.finish(operation, outcome: .executionFailed) }
            }
            busy = false
            await refresh()
            diagnostics.refreshID = UUID(); diagnostics.environmentRefreshID = UUID()
        }
    }
}

struct SteamLifecycleView: View {
    @EnvironmentObject private var diagnostics: AppDiagnosticsModel
    @StateObject private var model = SteamLifecycleModel()
    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Text("Steam: \(model.state.rawValue)").font(.headline).accessibilityIdentifier("lifecycle-state")
                HStack {
                    Button("Launch Windows Steam") { model.control(stop: false, diagnostics: diagnostics) }
                        .disabled(model.busy || model.state != .stopped).accessibilityIdentifier("launch-steam")
                    Button("Stop Windows Steam") { model.control(stop: true, diagnostics: diagnostics) }
                        .disabled(model.busy || ![.running, .starting].contains(model.state)).accessibilityIdentifier("stop-steam")
                }
                if let message = model.message { Text(message).font(.callout) }
                Text("Quit Gamekit to leave Steam running. Stop waits up to 30 seconds before forcing the managed environment to close.")
                    .font(.caption).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
        }
        .task {
            await model.refresh()
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--launch-steam") { model.control(stop: false, diagnostics: diagnostics) }
            #endif
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                await model.refresh()
            }
        }
    }
}
