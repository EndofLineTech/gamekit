import GamekitCore
import SwiftUI
import UniformTypeIdentifiers

private struct GameProfileDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        self.data = data
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

struct GameProfileTransferControls: View {
    let game: InstalledSteamGame
    let isLocal: Bool
    @Binding var working: Bool
    @Binding var status: String?
    let changed: @MainActor () async -> Void
    @EnvironmentObject private var setup: SetupModel
    @State private var importing = false
    @State private var exporting = false
    @State private var document = GameProfileDocument(data: Data())

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button("Import JSON…") { importing = true }
                    .accessibilityIdentifier("import-game-profile")
                Button("Export JSON…") { exportProfile() }
                    .accessibilityIdentifier("export-game-profile")
                if isLocal {
                    Button("Use automatic profile") { restoreAutomatic() }
                        .accessibilityIdentifier("restore-automatic-game-profile")
                }
            }.disabled(working || setup.isBusy)
            Text(isLocal
                 ? "Your imported profile takes precedence over wiki updates. Saved user settings still override its defaults."
                 : "Import a profile for this Steam AppID, or export a portable profile to edit or share. Saved user settings are separate.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            switch result {
            case .success(let url): importProfile(url)
            case .failure(let error):
                if (error as? CocoaError)?.code != .userCancelled { status = "The JSON file could not be opened." }
            }
        }
        .fileExporter(isPresented: $exporting, document: document, contentType: .json,
                      defaultFilename: String(game.id)) { result in
            switch result {
            case .success: status = "Profile JSON exported."
            case .failure(let error):
                if (error as? CocoaError)?.code != .userCancelled { status = "The profile could not be saved to that location." }
            }
        }
    }

    private func importProfile(_ url: URL) {
        working = true
        Task {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() }; working = false }
            do {
                try await GameProfileStore(root: AppStorageLocations.metadata).importProfile(from: url, appID: game.id)
                await changed()
                status = "Imported profile for AppID \(game.id). It takes precedence over wiki updates and applies at the next launch."
            } catch {
                status = "Import failed. Choose a valid profile for AppID \(game.id) using a supported schema, no larger than 32 KiB. The previous profile was preserved."
            }
        }
    }

    private func exportProfile() {
        working = true
        Task {
            defer { working = false }
            do {
                document = GameProfileDocument(data: try await GameProfileStore(root: AppStorageLocations.metadata)
                    .exportProfile(appID: game.id, name: game.name))
                exporting = true
            } catch { status = "The profile could not be exported. Check its JSON and try again." }
        }
    }

    private func restoreAutomatic() {
        working = true
        Task {
            defer { working = false }
            do {
                try await GameProfileStore(root: AppStorageLocations.metadata).removeImportedProfile(appID: game.id)
                await changed()
                status = "Imported profile removed. Using the latest available wiki or bundled profile, or defaults if none exists."
            } catch { status = "The imported profile could not be removed. Try again when other profile operations finish." }
        }
    }
}
