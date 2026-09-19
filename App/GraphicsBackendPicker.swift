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
                get: { setup.layout.graphicsBackend },
                set: { setup.chooseGraphicsBackend($0, diagnostics: diagnostics) }))
                .frame(width: 250)
        }
        .disabled(setup.isBusy || setup.selectionLocked)
    }
}

/// Native menu item enablement is explicit: SwiftUI's menu Picker does not
/// consistently preserve `.disabled` on tagged Text entries on macOS.
private struct BackendPopUp: NSViewRepresentable {
    @Binding var selection: D3DMetalBackend
    @Environment(\.isEnabled) private var isEnabled

    func makeCoordinator() -> Coordinator { Coordinator(selection: $selection) }

    func makeNSView(context: Context) -> NSPopUpButton {
        let control = NSPopUpButton(frame: .zero, pullsDown: false)
        control.addItems(withTitles: [D3DMetalBackend.automatic.title, D3DMetalBackend.metal3.title,
                                     "DXVK (In Dev)", "DXMT (In Dev)"])
        control.menu?.autoenablesItems = false
        control.item(at: 2)?.isEnabled = false
        control.item(at: 3)?.isEnabled = false
        control.target = context.coordinator
        control.action = #selector(Coordinator.changed(_:))
        control.setAccessibilityIdentifier("graphics-backend-picker")
        control.setAccessibilityLabel("Shared graphics backend")
        control.toolTip = "Applies to all games in managed Windows Steam. DXVK and DXMT are in development and cannot be selected yet."
        return control
    }

    func updateNSView(_ control: NSPopUpButton, context: Context) {
        context.coordinator.selection = $selection
        control.isEnabled = isEnabled
        control.selectItem(at: selection == .automatic ? 0 : 1)
    }

    final class Coordinator: NSObject {
        var selection: Binding<D3DMetalBackend>
        init(selection: Binding<D3DMetalBackend>) { self.selection = selection }
        @objc func changed(_ sender: NSPopUpButton) {
            guard sender.isEnabled, sender.indexOfSelectedItem == 0 || sender.indexOfSelectedItem == 1 else {
                sender.selectItem(at: selection.wrappedValue == .automatic ? 0 : 1)
                return
            }
            selection.wrappedValue = sender.indexOfSelectedItem == 0 ? .automatic : .metal3
        }
    }
}
