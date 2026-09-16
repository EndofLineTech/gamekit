import GamekitCore
import SwiftUI
import UniformTypeIdentifiers

private struct DiagnosticExportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        self.data = data
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

struct DiagnosticsView: View {
    @EnvironmentObject private var model: AppDiagnosticsModel
    @State private var summaries: [DiagnosticSummary] = []
    @State private var errorMessage: String?
    @State private var exporting = false
    @State private var exportDocument = DiagnosticExportDocument(data: Data())
    @State private var localOutput: DiagnosticLocalOutput?
    @State private var showingOutput = false

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("Local diagnostics", systemImage: "doc.text.magnifyingglass").font(.headline)
                    Spacer()
                    Button("Reload logs") { model.refreshID = UUID() }
                }
                Text("Summary exports exclude captured output, paths and session fields.")
                    .font(.caption).foregroundStyle(.secondary)
                if model.recordingProblem {
                    Text("Some diagnostic output could not be saved. Runtime results are reported separately.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                if let errorMessage { Text(errorMessage).foregroundStyle(.secondary) }
                if summaries.isEmpty {
                    Text("No recorded operations yet.").foregroundStyle(.secondary)
                }
                ForEach(summaries) { summary in
                    VStack(alignment: .leading, spacing: 6) {
                        Text("\(summary.stage.rawValue) · \(summary.component.rawValue) · \(summary.category.rawValue)")
                            .font(.subheadline.weight(.semibold))
                        Text(summary.recommendation).font(.caption).foregroundStyle(.secondary)
                        if summary.checkpointFailed {
                            Text("An intermediate checkpoint could not be saved.").font(.caption)
                        }
                        if summary.outputTruncated || summary.outputIncomplete {
                            Text("Captured output is truncated or incomplete.").font(.caption)
                        }
                        HStack {
                            Text(summary.startedAt, style: .time).font(.caption.monospacedDigit())
                            Spacer()
                            Button("View local output") { Task { await showLocal(summary.id) } }
                                .accessibilityIdentifier("local-diagnostic-\(summary.id.uuidString)")
                            Button("Export summary") { Task { await export(summary.id) } }
                                .accessibilityIdentifier("export-diagnostic-\(summary.id.uuidString)")
                        }
                    }
                    .padding(.vertical, 6)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
        }
        .task(id: model.refreshID) { await reload() }
        .fileExporter(isPresented: $exporting, document: exportDocument, contentType: .json,
                      defaultFilename: "Gamekit-diagnostic") { result in
            if case .failure = result { errorMessage = "The summary could not be exported." }
        }
        .sheet(isPresented: $showingOutput) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Local output — excluded from summary exports").font(.headline)
                ScrollView([.vertical, .horizontal]) {
                    Text("STDOUT\n\(String(decoding: localOutput?.stdout ?? Data(), as: UTF8.self))\n\nSTDERR\n\(String(decoding: localOutput?.stderr ?? Data(), as: UTF8.self))")
                        .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                }
                Button("Close") { showingOutput = false }
            }
            .padding(20).frame(width: 760, height: 480)
        }
    }

    private func reload() async {
        guard let store = model.store else { errorMessage = "Diagnostics storage is unavailable."; return }
        do {
            let loaded = try await store.summaries()
            try Task.checkCancellation()
            summaries = loaded; errorMessage = nil
        } catch is CancellationError {} catch {
            guard !Task.isCancelled else { return }
            errorMessage = "Recorded diagnostics could not be read; files were preserved."
        }
    }
    private func showLocal(_ id: UUID) async {
        do {
            guard let store = model.store else { return }
            localOutput = try await store.localOutput(id)
            showingOutput = true
        } catch { errorMessage = "Local output is unavailable or has expired." }
    }
    private func export(_ id: UUID) async {
        do {
            guard let store = model.store else { return }
            exportDocument = DiagnosticExportDocument(data: try await store.exportSummary(id))
            exporting = true
        } catch { errorMessage = "The summary is unavailable or has expired." }
    }
}
