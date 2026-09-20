import AppKit
import GameController
import GamekitCore
import SwiftUI

private struct ControllerReading: Identifiable, Equatable {
    let id: ObjectIdentifier
    let name: String
    let category: String
    let input: String
}

@MainActor
private final class ControllersModel: ObservableObject {
    @Published private(set) var controllers: [ControllerReading] = []
    @Published private(set) var message: String?

    init() {
        // A launcher preview must not request background gamepad events while
        // the Windows game or Steam is the foreground application.
        GCController.shouldMonitorBackgroundEvents = false
    }

    func refresh() {
        let readings = GCController.controllers().map { controller in
            let input: String
            if !NSApplication.shared.isActive {
                input = "Input preview pauses while Gamekit is in the background."
            } else if let pad = controller.extendedGamepad {
                let buttons: [(String, GCControllerButtonInput?)] = [
                    ("A / Cross", pad.buttonA), ("B / Circle", pad.buttonB),
                    ("X / Square", pad.buttonX), ("Y / Triangle", pad.buttonY),
                    ("LB / L1", pad.leftShoulder), ("RB / R1", pad.rightShoulder),
                    ("Menu", pad.buttonMenu), ("Options", pad.buttonOptions),
                    ("Left stick", pad.leftThumbstickButton), ("Right stick", pad.rightThumbstickButton),
                    ("Up", pad.dpad.up), ("Down", pad.dpad.down), ("Left", pad.dpad.left), ("Right", pad.dpad.right)
                ]
                let pressed = buttons.filter { $0.1?.isPressed == true }.map(\.0)
                input = "Buttons: " + (pressed.isEmpty ? "none" : pressed.joined(separator: ", ")) + "\n" +
                    String(format: "Left stick: %+.2f, %+.2f · Right stick: %+.2f, %+.2f\nTriggers: L %.2f · R %.2f",
                           pad.leftThumbstick.xAxis.value, pad.leftThumbstick.yAxis.value,
                           pad.rightThumbstick.xAxis.value, pad.rightThumbstick.yAxis.value,
                           pad.leftTrigger.value, pad.rightTrigger.value)
            } else {
                input = "Limited controller profile. Check supported inputs in Steam."
            }
            return ControllerReading(id: ObjectIdentifier(controller), name: controller.vendorName ?? "Game controller",
                                     category: controller.productCategory, input: input)
        }
        if readings != controllers { controllers = readings }
    }

    func openSteamSettings(setup: SetupModel, diagnostics: AppDiagnosticsModel) {
        guard setup.actions.launch || setup.actions.show,
              let token = setup.begin("Opening Steam controller settings") else { return }
        message = "Opening controller settings in managed Windows Steam…"
        Task {
            defer { setup.end(token); setup.refresh(diagnostics: diagnostics) }
            do {
                let lifecycle = SteamLifecycle(store: try EnvironmentStore(root: AppStorageLocations.metadata), layout: setup.layout)
                try await lifecycle.openControllerSettings()
                let shown = (try? await SteamWindowPresentation.bringForward(using: lifecycle)) == true
                message = shown ? "Use Steam's controller input test, then configure Steam Input for your game."
                    : "Controller settings requested. Select Windows Steam in the Dock if its window is hidden."
            } catch { message = AppFailure.message(error) }
        }
    }
}

struct ControllersView: View {
    @EnvironmentObject private var setup: SetupModel
    @EnvironmentObject private var diagnostics: AppDiagnosticsModel
    @StateObject private var model = ControllersModel()
    @State private var expanded = false

    var body: some View {
        GroupBox {
            DisclosureGroup(isExpanded: $expanded) {
                VStack(alignment: .leading, spacing: 12) {
                    if model.controllers.isEmpty {
                        Text("No controllers detected by macOS. Connect by USB or pair in macOS Bluetooth settings.")
                            .accessibilityIdentifier("controllers-empty")
                    }
                    ForEach(model.controllers) { controller in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(controller.name).font(.headline)
                            Text("\(controller.category) · Connected to macOS").font(.caption).foregroundStyle(.secondary)
                            Text(controller.input).font(.system(.caption, design: .monospaced))
                        }
                    }
                    Text("Hold buttons or move sticks/triggers while Gamekit is foreground to check macOS input. This does not yet prove input reaches a Windows game.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Steam controller settings", systemImage: "gamecontroller") {
                        model.openSteamSettings(setup: setup, diagnostics: diagnostics)
                    }
                    .disabled(!(setup.actions.launch || setup.actions.show))
                    .accessibilityIdentifier("steam-controller-settings")
                    Text("For DualSense, configure PlayStation Steam Input support in Windows Steam. For Xbox controllers, start with the game's native controller support or a Steam Input gamepad layout. Mouse-only games need a keyboard/mouse layout.")
                        .font(.callout)
                    if let message = model.message { Text(message).font(.callout).accessibilityIdentifier("controller-status") }
                }.padding(.top, 8)
            } label: {
                Label("Controllers · \(model.controllers.count) connected to macOS", systemImage: "gamecontroller.fill")
                    .font(.headline)
            }
            .padding(12)
        }
        .task {
            while !Task.isCancelled {
                model.refresh()
                do { try await Task.sleep(for: .milliseconds(expanded ? 150 : 1000)) } catch { return }
            }
        }
    }
}
