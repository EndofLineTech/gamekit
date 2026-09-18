import GamekitCore
import SwiftUI

struct RecoveryArchivesView: View {
    @EnvironmentObject private var setup: SetupModel
    @EnvironmentObject private var diagnostics: AppDiagnosticsModel
    @State private var archives: [SteamRecoveryArchiveInfo] = []
    @State private var status = "Inspect archives to see retained data and cleanup eligibility."
    @State private var selected: SteamRecoveryArchiveInfo?
    @State private var confirmCleanup = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Recovery archives").font(.headline)
            Text("Old prefixes retain settings, sign-in data and any saves left inside them. Cleanup permanently removes that archived prefix after downloads have been restored. External libraries and the current environment stay in place.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Inspect recovery archives") { run() }
                .disabled(setup.isBusy).accessibilityIdentifier("inspect-recovery-archives")
            Text(status).font(.caption).accessibilityIdentifier("recovery-archives-status")
            ForEach(archives) { archive in
                HStack(alignment: .top) {
                    VStack(alignment: .leading) {
                        if let date = archive.createdAt { Text(date, style: .date) }
                        Text(archive.id).font(.caption).textSelection(.enabled)
                        Text(description(archive)).font(.caption)
                    }
                    Spacer()
                    if archive.status == .completed {
                        Button("Clean up archive…") { selected = archive; confirmCleanup = true }
                            .disabled(setup.isBusy || !setup.actions.reset)
                            .accessibilityIdentifier("clean-recovery-archive-\(archive.id)")
                    }
                }
            }
            Text("Sizes are logical file bytes, not guaranteed reclaimed disk space. Small recovery receipts remain after cleanup. Archives with unfinished or unverifiable recovery are protected. Stop Steam before cleanup.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .confirmationDialog("Permanently clean up this recovery archive?", isPresented: $confirmCleanup, titleVisibility: .visible, presenting: selected) { archive in
            Button("Delete archived prefix", role: .destructive) { run(cleaning: archive.id) }
            Button("Cancel", role: .cancel) {}
        } message: { archive in
            Text("Archive \(archive.id): deletes its old settings, sign-in data and remaining local saves. Restored downloads, external libraries and the current environment are preserved. This cannot be undone.")
        }
    }

    private func description(_ archive: SteamRecoveryArchiveInfo) -> String {
        let size = archive.bytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "Size unavailable"
        let state: String
        switch archive.status {
        case .completed: state = "Completed — eligible for cleanup"
        case .protected: state = "Protected — unfinished or unverified recovery"
        case .cleaned: state = "Cleaned — receipt retained"
        }
        return "\(size) · \(state)"
    }

    private func run(cleaning archiveID: String? = nil) {
        guard let token = setup.begin(archiveID == nil ? "Inspecting recovery archives" : "Cleaning recovery archive") else { return }
        let layout = setup.layout
        Task {
            defer { setup.end(token); setup.refresh(diagnostics: diagnostics) }
            do {
                let store = try EnvironmentStore(root: AppStorageLocations.metadata)
                let recovery = SteamRecovery(store: store, layout: layout)
                if let archiveID { try await recovery.cleanArchive(archiveID, confirmed: true) }
                archives = try await recovery.archives()
                status = archiveID != nil ? "Archived prefix cleaned. Recovery receipt retained." : (archives.isEmpty ? "No recovery archives." : "Archive inspection complete.")
            } catch {
                archives = []
                status = AppFailure.message(error) + " Inspect again before retrying cleanup."
            }
        }
    }
}
