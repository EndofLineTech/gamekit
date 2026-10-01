import AppKit
import SwiftUI

/// Shared native surfaces for the library, inspector and management destinations.
/// System colors/materials adapt to macOS appearance and accessibility settings.
enum LibraryVisualStyle {
    static let accent = Color.accentColor
    static let panel = Color(nsColor: .controlBackgroundColor)
    static let border = Color.primary.opacity(0.11)
    static let contentSpacing: CGFloat = 28
    static let controlSpacing: CGFloat = 10
    static let launcherMarkOpacity = 0.75
}

struct LibraryPanel<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(LibraryVisualStyle.panel, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(LibraryVisualStyle.border))
    }
}

/// A 2:3 cover. `mark` is the transparent launcher icon supplied by the caller;
/// no opaque badge is generated here. Landscape headers never fill this portrait
/// slot. Selection is a visible outline, not a Play affordance.
struct LibraryCover<Mark: View>: View {
    let title: String
    let portrait: NSImage?
    let selected: Bool
    let favorite: Bool
    let mark: Mark
    var fallbackIcon: NSImage? = nil

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                if let portrait {
                    Image(nsImage: portrait).resizable().scaledToFill()
                        .frame(width: geometry.size.width, height: geometry.size.height).clipped()
                } else {
                    LinearGradient(colors: [LibraryVisualStyle.accent.opacity(0.85), Color.teal.opacity(0.65),
                                            Color(nsColor: .underPageBackgroundColor)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                    VStack(alignment: .leading) {
                        Spacer()
                        Group {
                            if let fallbackIcon {
                                Image(nsImage: fallbackIcon).resizable().scaledToFit()
                                    .frame(width: geometry.size.width * 0.32, height: geometry.size.width * 0.32)
                            } else {
                                Image(systemName: "gamecontroller.fill")
                                    .font(.system(size: max(20, geometry.size.width * 0.22)))
                            }
                        }
                        .accessibilityHidden(true)
                        Text(title)
                            .font(.system(size: min(24, max(13, geometry.size.width * 0.14)), weight: .bold))
                            .lineLimit(3)
                            .minimumScaleFactor(0.8)
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(max(8, geometry.size.width * 0.09))
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .overlay(alignment: .topLeading) {
                mark.foregroundStyle(.white).opacity(LibraryVisualStyle.launcherMarkOpacity)
                    .shadow(color: .black.opacity(0.8), radius: 3)
                    .padding(max(5, geometry.size.width * 0.07))
            }
            .overlay(alignment: .topTrailing) {
                if favorite {
                    Image(systemName: "star.fill")
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.8), radius: 3)
                        .padding(max(5, geometry.size.width * 0.07))
                        .accessibilityLabel("Favorite")
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10)
                .strokeBorder(selected ? LibraryVisualStyle.accent : .clear, lineWidth: selected ? 3 : 0))
            .shadow(color: .black.opacity(0.16), radius: 9, y: 4)
        }
        .aspectRatio(2 / 3, contentMode: .fit)
        .accessibilityHidden(true) // The tile/row supplies title, source and state.
    }
}

struct LibraryGameTile<Mark: View>: View {
    let title: String
    let source: String
    let state: String
    let needsAttention: Bool
    let reportedSize: String
    let portrait: NSImage?
    let selected: Bool
    let favorite: Bool
    let mark: Mark
    var fallbackIcon: NSImage? = nil
    var sizeProvenance = "Steam-reported size"

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            LibraryCover(title: title, portrait: portrait, selected: selected, favorite: favorite,
                         mark: mark, fallbackIcon: fallbackIcon)
            Text(title).font(.headline).lineLimit(2)
            Text("\(source) · \(reportedSize)").font(.caption).foregroundStyle(.secondary).lineLimit(2)
            if needsAttention {
                Label(state, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title), \(source), \(state), \(sizeProvenance): \(reportedSize)\(favorite ? ", favorite" : "")")
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

struct LibraryInspectorSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: LibraryVisualStyle.controlSpacing) {
            Text(title).font(.headline)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 12)
    }
}

#Preview("Library components · Light") {
    LibraryPanel {
        HStack(alignment: .top, spacing: LibraryVisualStyle.contentSpacing) {
            LibraryGameTile(title: "Installed game", source: "Windows Steam", state: "Installed",
                            needsAttention: false, reportedSize: "Unavailable", portrait: nil, selected: true, favorite: true,
                            mark: Image("SteamLauncherMark").resizable().frame(width: 25, height: 25))
                .frame(width: 145)
            LibraryInspectorSection(title: "Installation") {
                Text("Select a game to see its details.").foregroundStyle(.secondary)
            }
        }
    }
    .frame(width: 560)
    .padding()
    .environment(\.colorScheme, .light)
}

#Preview("Library components · Dark") {
    LibraryPanel {
        LibraryGameTile(title: "Installed game", source: "Windows Steam", state: "Needs attention",
                        needsAttention: true, reportedSize: "Unavailable", portrait: nil, selected: false, favorite: false,
                        mark: Image("SteamLauncherMark").resizable().frame(width: 25, height: 25))
            .frame(width: 125)
    }
    .frame(width: 340)
    .padding()
    .environment(\.colorScheme, .dark)
}
