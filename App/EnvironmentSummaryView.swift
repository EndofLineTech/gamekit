import GamekitCore
import SwiftUI

/// Fresh runtime/process observations drive registered-environment summaries.
struct EnvironmentSummaryView: View {
    @EnvironmentObject private var diagnostics: AppDiagnosticsModel
    @EnvironmentObject private var setup: SetupModel
    @State private var environments: [ReconciledEnvironment] = []
    @State private var failed = false
    @State private var refresh = 0

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("Saved environments", systemImage: "externaldrive")
                        .font(.headline)
                    Spacer()
                    Button("Reload") { refresh += 1 }
                }
                if failed {
                    Text("Environment checks could not be completed. Existing files have been preserved.")
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("metadata-error")
                } else if environments.isEmpty {
                    Text("No registered environment metadata yet.")
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("metadata-empty")
                } else {
                    ForEach(environments, id: \.record.id) { environment in
                        HStack {
                            Text(environment.record.name)
                            Spacer()
                            Text(label(for: environment.state))
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("environment-\(environment.record.id.rawValue)")
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
        }
        .task(id: "\(refresh)-\(diagnostics.environmentRefreshID)") { await reload() }
    }

    private func label(for state: EnvironmentState) -> String {
        switch state {
        case .unverified: "Not checked"
        case .missingPrerequisites: "Missing prerequisites"
        case .readyToInstall: "Ready to install"
        case .installing: "Installing"
        case .installed: "Installed"
        case .running: "Running"
        case .failed: "Needs attention"
        case .interrupted: "Interrupted"
        }
    }

    private func reload() async {
        do {
            let root = AppStorageLocations.metadata
            let store = try EnvironmentStore(root: root)
            let records = try await store.loadAll()
            let layout = setup.layout
            var refreshed: [ReconciledEnvironment] = []
            for record in records {
                var process: ProcessObservation = .notChecked
                if record.runtime == layout.profile.identity {
                    let prefix = try await store.checkedPrefixURL(for: record.id)
                    let inventory = await RuntimeProcessObserver().inspect(record: record, prefix: prefix, layout: layout)
                    process = inventory.observation(installation: record.installation)
                }
                refreshed.append(try await store.reconcile(record.id, process: process,
                                                            prerequisites: setup.report?.prerequisites ?? .notChecked,
                                                            expectedRevision: record.revision))
            }
            try Task.checkCancellation()
            environments = refreshed
            failed = false
        } catch is CancellationError {
            // A newer reload or closed window supersedes this presentation task.
        } catch {
            guard !Task.isCancelled else { return }
            environments = []
            failed = true
        }
    }
}
