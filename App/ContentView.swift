import GamekitCore
import SwiftUI

struct ContentView: View {
    private let operatingSystem = ProcessInfo.processInfo.operatingSystemVersion

    private var architecture: HostArchitecture {
        #if arch(arm64)
        .arm64
        #elseif arch(x86_64)
        .x86_64
        #else
        .unknown
        #endif
    }

    private var hostMatchesScope: Bool {
        PrototypeHostPolicy.failures(
            macOSMajorVersion: operatingSystem.majorVersion,
            architecture: architecture
        ).isEmpty
    }

    var body: some View {
        ScrollView {
            content
        }
        .frame(minWidth: 640, minHeight: 620)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(spacing: 16) {
                Image(systemName: "gamecontroller.fill")
                    .font(.system(size: 42))
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Gamekit")
                        .font(.largeTitle.bold())
                    Text("Windows Steam on macOS")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("Foundation build")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.quaternary, in: Capsule())
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 14) {
                    Label("Steam runtime recipe", systemImage: "shippingbox")
                        .font(.headline)
                    Text("Sikarugir Wine 10.0 revision 6 + Apple D3DMetal 4.0b2")
                        .accessibilityIdentifier("runtime-recipe")
                    Text("Two fresh Steam environments passed manual feasibility testing. The native core now models and stores environment metadata.")
                        .foregroundStyle(.secondary)
                    Link("Read the validated runtime recipe",
                         destination: URL(string: "https://github.com/EndofLineTech/gamekit/blob/dev/docs/runtime-revision.md")!)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Prototype target: Apple silicon · macOS \(PrototypeHostPolicy.macOSMajorVersion)")
                    .font(.headline)
                Label(
                    hostMatchesScope ? "Host is in prototype scope" : "Host is outside the evaluated scope",
                    systemImage: hostMatchesScope ? "checkmark.circle" : "info.circle"
                )
                .accessibilityIdentifier("host-scope")
                Text("Host eligibility does not check Rosetta or the installed runtime. Runtime detection and Steam controls follow in later milestones.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            EnvironmentSummaryView()
            Spacer(minLength: 0)
        }
        .padding(32)
    }
}
