import GamekitCore
import SwiftUI

enum AppStorageLocations {
    static var metadata: URL {
        override("--metadata-root") ?? EnvironmentStore.applicationSupportRoot
    }
    static var diagnostics: URL {
        if let explicit = override("--diagnostics-root") { return explicit }
        if let metadata = override("--metadata-root") {
            return metadata.deletingLastPathComponent().appendingPathComponent("GamekitLogs")
        }
        return DiagnosticStore.defaultBase
    }
    private static func override(_ flag: String) -> URL? {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) {
            return URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
        }
        #endif
        return nil
    }
}

@MainActor
final class AppDiagnosticsModel: ObservableObject {
    let store: DiagnosticStore?
    @Published var refreshID = UUID()
    @Published var environmentRefreshID = UUID()
    @Published var recordingProblem = false

    init() {
        store = try? DiagnosticStore(base: AppStorageLocations.diagnostics)
        recordingProblem = store == nil
    }

    func execute(_ request: CommandRequest, layout: RuntimeLayout) async throws -> CommandResult {
        guard let store else {
            recordingProblem = true
            return try await ProcessExecutor().run(request)
        }
        let component: DiagnosticComponent
        switch request.executable.lastPathComponent {
        case "arch": component = .rosetta
        case "codesign": component = .graphics
        case "wine", "wine64": component = .wine
        default: component = .application
        }
        let result = await DiagnosticCommandRunner(store: store).run(request, stage: .runtimeProbe,
                                context: .init(component: component, runtimeSelection: layout.profile.identity))
        recordingProblem = recordingProblem || result.storageIssue != nil
        refreshID = UUID()
        return try result.value()
    }
}
