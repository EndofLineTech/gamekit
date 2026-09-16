import GamekitCore
import SwiftUI

/// Fresh runtime/process observations drive registered-environment summaries.
struct EnvironmentSummaryView: View {
    @State private var environments: [ReconciledEnvironment] = []
    @State private var failed = false
    @State private var refresh = 0
    @State private var runtimeReport: RuntimeReport?

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("Saved environments", systemImage: "externaldrive")
                        .font(.headline)
                    Spacer()
                    Button("Reload") { refresh += 1 }
                }
                if let runtimeReport {
                    ForEach(runtimeReport.checks, id: \.prerequisite) { check in
                        Label(check.detail, systemImage: check.status == .passed ? "checkmark.circle" : "info.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
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
        .task(id: refresh) { await reload() }
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
            var root = EnvironmentStore.applicationSupportRoot
            #if DEBUG
            // UI tests opt into their own temporary store; never write fixtures to real user data.
            let arguments = ProcessInfo.processInfo.arguments
            if let index = arguments.firstIndex(of: "--metadata-root"), arguments.indices.contains(index + 1) {
                root = URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
            }
            #endif
            let store = try EnvironmentStore(root: root)
            let records = try await store.loadAll()
            let layout = RuntimeLayout(dataRoot: root)
            let report = try await RuntimeDetector().detect(layout, selection: layout.profile.identity)
            var refreshed: [ReconciledEnvironment] = []
            for record in records {
                var process: ProcessObservation = .notChecked
                if record.runtime == layout.profile.identity {
                    let prefix = try await store.checkedPrefixURL(for: record.id)
                    let inventory = await RuntimeProcessObserver().inspect(record: record, prefix: prefix, layout: layout)
                    process = inventory.observation(installation: record.installation)
                }
                refreshed.append(try await store.reconcile(record.id, process: process,
                                                            prerequisites: report.prerequisites,
                                                            expectedRevision: record.revision))
            }
            try Task.checkCancellation()
            runtimeReport = report
            environments = refreshed
            failed = false
        } catch is CancellationError {
            // A newer reload or closed window supersedes this presentation task.
        } catch {
            guard !Task.isCancelled else { return }
            environments = []
            runtimeReport = nil
            failed = true
        }
    }
}
