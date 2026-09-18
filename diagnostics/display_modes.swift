// Read-only macOS display inventory. Dimensions are explicitly labeled;
// framebuffer pixels are not assumed to equal the physical panel resolution.
import AppKit
import CoreGraphics
import Foundation

for screen in NSScreen.screens {
    guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { continue }
    let id = number.uint32Value
    print("SCREEN builtin=\(CGDisplayIsBuiltin(id)) frame=\(screen.frame) scale=\(screen.backingScaleFactor) safeTop=\(screen.safeAreaInsets.top)")
    if let mode = CGDisplayCopyDisplayMode(id) {
        print("CURRENT logical=\(mode.width)x\(mode.height) framebuffer=\(mode.pixelWidth)x\(mode.pixelHeight) Hz=\(mode.refreshRate)")
    }
    let options = [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary
    for mode in CGDisplayCopyAllDisplayModes(id, options) as? [CGDisplayMode] ?? [] {
        print("MODE logical=\(mode.width)x\(mode.height) framebuffer=\(mode.pixelWidth)x\(mode.pixelHeight) Hz=\(mode.refreshRate)")
    }
}
