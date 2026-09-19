import AppKit
import GamekitCore
import SwiftUI

struct GraphicsBackendPicker: View {
    @EnvironmentObject private var setup: SetupModel
    @EnvironmentObject private var diagnostics: AppDiagnosticsModel

    var body: some View {
        HStack {
            Text("Shared graphics backend")
            BackendPopUp(selection: Binding(
                get: { setup.layout.graphicsBackend.rawValue },
                set: { if let backend = GraphicsBackend(rawValue: $0) { setup.chooseGraphicsBackend(backend, diagnostics: diagnostics) } }), available: setup.availableGraphicsBackends)
                .frame(width: 250)
        }
        .disabled(setup.isBusy || setup.selectionLocked)
    }
}

struct GameGraphicsBackendPicker: View {
    @EnvironmentObject private var setup: SetupModel
    @Binding var selection: GameGraphicsOverride
    var body: some View {
        HStack {
            Text("Graphics backend")
            BackendPopUp(selection: Binding(get: { selection.rawValue }, set: {
                if let value = GameGraphicsOverride(rawValue: $0) { selection = value }
            }), available: setup.availableGraphicsBackends, perGame: true).frame(width: 250)
        }
    }
}

/// Native menu item enablement is explicit: SwiftUI's menu Picker does not
/// consistently preserve `.disabled` on tagged Text entries on macOS.
private struct BackendPopUp: NSViewRepresentable {
    @Binding var selection: String
    let available: Set<GraphicsBackend>
    var perGame = false
    @Environment(\.isEnabled) private var isEnabled
    private var values: [String] { (perGame ? ["inherit"] : []) + GraphicsBackend.allCases.map(\.rawValue) }
    private var titles: [String] { (perGame ? [GameGraphicsOverride.inherit.title] : []) + GraphicsBackend.allCases.map(\.title) }

    func makeCoordinator() -> Coordinator { Coordinator(selection: $selection, values: values) }

    func makeNSView(context: Context) -> NSPopUpButton {
        let control = NSPopUpButton(frame: .zero, pullsDown: false)
        control.addItems(withTitles: titles)
        control.menu?.autoenablesItems = false
        control.target = context.coordinator
        control.action = #selector(Coordinator.changed(_:))
        control.setAccessibilityIdentifier(perGame ? "game-graphics-backend-picker" : "graphics-backend-picker")
        control.setAccessibilityLabel(perGame ? "Graphics backend for this game" : "Shared graphics backend")
        control.toolTip = "DXMT/DXVK require installed payloads and Direct3D 10/11 games. Steam stays on D3DMetal. Changes apply at the next launch."
        return control
    }

    func updateNSView(_ control: NSPopUpButton, context: Context) {
        context.coordinator.selection = $selection
        context.coordinator.values = values
        control.isEnabled = isEnabled
        for (index, value) in values.enumerated() {
            let backend = GraphicsBackend(rawValue: value)
            let qualified = backend?.qualifiedForGames ?? true
            let enabled = qualified && (backend.map { available.contains($0) } ?? true)
            control.item(at: index)?.isEnabled = enabled
            control.item(at: index)?.title = !qualified ? "\(value.uppercased()) (In Dev)" : titles[index] + (enabled ? "" : " — Not installed")
        }
        control.selectItem(at: values.firstIndex(of: selection) ?? 0)
    }

    final class Coordinator: NSObject {
        var selection: Binding<String>
        var values: [String]
        init(selection: Binding<String>, values: [String]) { self.selection = selection; self.values = values }
        @objc func changed(_ sender: NSPopUpButton) {
            guard sender.isEnabled, values.indices.contains(sender.indexOfSelectedItem) else {
                sender.selectItem(at: values.firstIndex(of: selection.wrappedValue) ?? 0)
                return
            }
            selection.wrappedValue = values[sender.indexOfSelectedItem]
        }
    }
}
