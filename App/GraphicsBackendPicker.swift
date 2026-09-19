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
                set: { if let backend = D3DMetalBackend(rawValue: $0) { setup.chooseGraphicsBackend(backend, diagnostics: diagnostics) } }))
                .frame(width: 250)
        }
        .disabled(setup.isBusy || setup.selectionLocked)
    }
}

struct GameGraphicsBackendPicker: View {
    @Binding var selection: GameGraphicsOverride
    var body: some View {
        HStack {
            Text("Graphics backend")
            BackendPopUp(selection: Binding(get: { selection.rawValue }, set: {
                if let value = GameGraphicsOverride(rawValue: $0) { selection = value }
            }), perGame: true).frame(width: 250)
        }
    }
}

/// Native menu item enablement is explicit: SwiftUI's menu Picker does not
/// consistently preserve `.disabled` on tagged Text entries on macOS.
private struct BackendPopUp: NSViewRepresentable {
    @Binding var selection: String
    var perGame = false
    @Environment(\.isEnabled) private var isEnabled
    private var values: [String] { (perGame ? ["inherit"] : []) + ["automatic", "metal3"] }
    private var titles: [String] { (perGame ? [GameGraphicsOverride.inherit.title] : []) + [D3DMetalBackend.automatic.title, D3DMetalBackend.metal3.title] }

    func makeCoordinator() -> Coordinator { Coordinator(selection: $selection, values: values) }

    func makeNSView(context: Context) -> NSPopUpButton {
        let control = NSPopUpButton(frame: .zero, pullsDown: false)
        control.addItems(withTitles: titles + ["DXVK (In Dev)", "DXMT (In Dev)"])
        control.menu?.autoenablesItems = false
        control.item(at: values.count)?.isEnabled = false
        control.item(at: values.count + 1)?.isEnabled = false
        control.target = context.coordinator
        control.action = #selector(Coordinator.changed(_:))
        control.setAccessibilityIdentifier(perGame ? "game-graphics-backend-picker" : "graphics-backend-picker")
        control.setAccessibilityLabel(perGame ? "Graphics backend for this game" : "Shared graphics backend")
        control.toolTip = (perGame ? "Applies to this game's next launch." : "Default for Windows Steam and games without an override.") + " DXVK and DXMT are in development."
        return control
    }

    func updateNSView(_ control: NSPopUpButton, context: Context) {
        context.coordinator.selection = $selection
        context.coordinator.values = values
        control.isEnabled = isEnabled
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
