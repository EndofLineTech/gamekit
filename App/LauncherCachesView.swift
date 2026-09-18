import GamekitCore
import SwiftUI

struct LauncherCachesView: View {
    @EnvironmentObject private var setup: SetupModel
    @EnvironmentObject private var diagnostics: AppDiagnosticsModel
    @State private var entries: [LauncherCacheEntry] = []
    @State private var status = "Inspect generated game launchers before cleanup."
    @State private var selected: LauncherCacheEntry?
    @State private var confirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Generated game launchers").font(.headline)
            Button("Inspect launcher caches") { run() }
                .disabled(setup.isBusy).accessibilityIdentifier("inspect-launcher-caches")
            Text(status).font(.caption).accessibilityIdentifier("launcher-caches-status")
            ForEach(entries) { entry in
                HStack {
                    VStack(alignment: .leading) {
                        Text(entry.id).font(.caption).textSelection(.enabled)
                        Text("\(entry.status.rawValue) · \(entry.bytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "Size not measured")").font(.caption)
                    }
                    Spacer()
                    if entry.canClean {
                        Button("Remove obsolete cache…") { selected = entry; confirmation = true }
                            .disabled(setup.isBusy).accessibilityIdentifier("clean-launcher-cache-\(entry.id)")
                    }
                }
            }
            Text("Stop managed Steam first. Only verified obsolete game bundles and empty probe folders are removable. Current shared-pe-v2 launchers, Windows Steam, source runtimes and game data are retained. Sizes are logical bytes; shared files may free less disk space.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .confirmationDialog("Remove this obsolete launcher cache?", isPresented: $confirmation, titleVisibility: .visible, presenting: selected) { entry in
            Button("Remove obsolete cache", role: .destructive) { run(cleaning: entry) }
            Button("Cancel", role: .cancel) {}
        } message: { entry in
            Text("Removes \(entry.id). This is a generated launcher, not installed game data. Current launchers and source runtimes are preserved.")
        }
    }

    private func run(cleaning entry: LauncherCacheEntry? = nil) {
        guard let token = setup.begin(entry == nil ? "Inspecting launcher caches" : "Removing obsolete launcher cache") else { return }
        Task {
            defer { setup.end(token); setup.refresh(diagnostics: diagnostics) }
            do {
                let maintenance = LauncherCacheMaintenance(store: try EnvironmentStore(root: AppStorageLocations.metadata))
                if let entry { try await maintenance.clean(entry, confirmed: true) }
                entries = try await maintenance.inspect()
                status = entry == nil ? (entries.isEmpty ? "No game launcher caches." : "Cache inspection complete.") : "Obsolete launcher cache removed."
            } catch {
                entries = []
                status = AppFailure.message(error) + " Inspect again before retrying."
            }
        }
    }
}
