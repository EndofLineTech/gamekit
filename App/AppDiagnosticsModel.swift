import AppKit
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
    @Published private(set) var debugMode = false
    @Published private(set) var debugCapturing = false
    @Published private(set) var debugStatus = "Debug capture is off."
    private var debugTask: Task<Void, Never>?

    init() {
        store = try? DiagnosticStore(base: AppStorageLocations.diagnostics)
        recordingProblem = store == nil
    }

    func setDebugMode(_ enabled: Bool) {
        debugMode = enabled
        if !enabled { stopDebugCapture() }
        if !debugCapturing { debugStatus = enabled ? "Ready to capture the next game launched from Gamekit." : "Debug capture is off." }
    }

    func stopDebugCapture() {
        debugTask?.cancel()
        if debugCapturing { debugStatus = "Stopping the sampler…" }
    }

    func captureGameIfEnabled(_ game: InstalledSteamGame, layout: RuntimeLayout) {
        guard debugMode, debugTask == nil else { return }
        guard let store, let executable = Bundle.main.executableURL else {
            debugStatus = "Debug capture storage is unavailable."; return
        }
        let helper = executable.deletingLastPathComponent().appendingPathComponent("GamekitProcessCounters")
        guard FileManager.default.isExecutableFile(atPath: helper.path) else {
            debugStatus = "The packaged counter helper is unavailable."; return
        }
        debugCapturing = true
        debugStatus = "Waiting for \(game.name)'s process (up to 60 seconds)…"
        debugTask = Task { [weak self] in
            guard let self else { return }
            defer { debugCapturing = false; debugTask = nil; refreshID = UUID() }
            do {
                let lifecycle = SteamLifecycle(store: try EnvironmentStore(root: AppStorageLocations.metadata), layout: layout)
                let deadline = ContinuousClock.now.advanced(by: .seconds(60))
                var target: ScopedRuntimeProcess?
                let identifier = "tech.endofline.gamekit.game.\(game.id)"
                let loaderRoot = layout.gameApplicationsRoot.appendingPathComponent(String(game.id)).path + "/"
                while !Task.isCancelled && ContinuousClock.now < deadline {
                    if let snapshot = try? await lifecycle.diagnosticProcesses() {
                        let candidates = snapshot.processes.filter { process in
                            guard process.role == .other, let app = NSRunningApplication(processIdentifier: process.identity.pid) else { return false }
                            let matchingLoader = app.executableURL?.standardizedFileURL.path.hasPrefix(loaderRoot) == true
                            return app.activationPolicy == .regular && (app.bundleIdentifier == identifier || matchingLoader)
                        }
                        if candidates.count == 1 { target = candidates[0]; break }
                    }
                    try await Task.sleep(for: .milliseconds(500))
                }
                try Task.checkCancellation()
                guard let target else { debugStatus = "No uniquely identified game process appeared; no counters captured."; return }
                debugStatus = "Capturing \(game.name): CPU, memory and disk I/O (up to 60 seconds)…"
                let result = try await GamePerformanceCapture(helper: helper, diagnostics: store, lifecycle: lifecycle)
                    .capture(target: target, appID: game.id)
                debugStatus = result.samples > 0
                    ? "Debug capture saved: \(result.samples) samples. Open its local output below."
                    : "The process ended before any counters were captured."
            } catch is CancellationError {
                debugStatus = "Debug capture stopped. This does not stop your game."
            } catch {
                debugStatus = "Debug capture ended early or was unavailable. Any recorded output is retained locally; this is not a game failure."
            }
        }
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
