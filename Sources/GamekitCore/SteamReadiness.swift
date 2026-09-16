import CoreGraphics
import Foundation

/// Objective UI-availability evidence, not proof of authentication or game compatibility.
public enum SteamReadiness {
    public static func ready(snapshot: RuntimeProcessSnapshot, windowOwners: Set<Int32>) -> Bool {
        guard snapshot.complete, snapshot.processes.contains(where: { $0.role == .steam }) else { return false }
        let tags = snapshot.processes.compactMap(\.sessionID)
        guard tags.count == snapshot.processes.count, Set(tags).count == 1 else { return false }
        return snapshot.processes.contains { $0.role == .steamUI && windowOwners.contains($0.identity.pid) }
    }

    public static func windowOwners() -> Set<Int32> {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [] }
        return Set(windows.compactMap { window in
            guard let pid = window[kCGWindowOwnerPID as String] as? NSNumber,
                  let layer = window[kCGWindowLayer as String] as? NSNumber, layer.intValue == 0,
                  let alpha = window[kCGWindowAlpha as String] as? NSNumber, alpha.doubleValue > 0,
                  let bounds = window[kCGWindowBounds as String] as? [String: Any],
                  let rectangle = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  rectangle.width >= 200, rectangle.height >= 120 else { return nil }
            return pid.int32Value
        })
    }
}
