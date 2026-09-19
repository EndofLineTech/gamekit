import AppKit
import CoreImage
import ScreenCaptureKit

// Diagnostic-only, bounded 45-second app-filtered capture. Compile separately
// with swiftc and use GAMEKIT_E6_VISUAL_TOOL in the opt-in launch harness.
// This changes presentation/compositing behavior; use for scene alignment,
// never as an unperturbed performance baseline. Output stays private locally.

final class Capture: NSObject, SCStreamOutput {
    let root: URL
    let context = CIContext()
    let log: FileHandle
    var index = 0
    init(root: URL) throws {
        self.root = root
        let url = root.appendingPathComponent("visual-frames.jsonl")
        FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        log = try FileHandle(forWritingTo: url)
    }
    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sample.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let status = attachments.first?[.status] as? Int, status == SCFrameStatus.complete.rawValue,
              let buffer = sample.imageBuffer else { return }
        let name = String(format: "visual-%04d.jpg", index)
        let row: [String: Any] = ["file": name, "receivedUnixTime": Date().timeIntervalSince1970,
            "presentationSeconds": sample.presentationTimeStamp.seconds,
            "displayTime": attachments.first?[.displayTime] as? UInt64 ?? 0]
        do {
            try context.writeJPEGRepresentation(of: CIImage(cvPixelBuffer: buffer), to: root.appendingPathComponent(name),
                colorSpace: CGColorSpaceCreateDeviceRGB(), options: [:])
            var data = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]); data.append(10)
            try log.write(contentsOf: data)
            index += 1
        } catch { fputs("capture output failure\n", stderr) }
    }
}

let pid = Int32(CommandLine.arguments[1])!
let root = URL(fileURLWithPath: CommandLine.arguments[2])
Task { @MainActor in
    do {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
        guard let app = content.applications.first(where: { $0.processID == pid }),
              let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) else { exit(2) }
        let filter = SCContentFilter(display: display, including: [app], exceptingWindows: [])
        let config = SCStreamConfiguration()
        config.width = 900; config.height = 584
        config.minimumFrameInterval = CMTime(value: 1, timescale: 10)
        config.queueDepth = 3; config.showsCursor = false
        let output = try Capture(root: root)
        let stream = SCStream(filter: filter, configuration: config, delegate: nil)
        let queue = DispatchQueue(label: "visual-capture")
        try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        try await Task.sleep(for: .seconds(45))
        try await stream.stopCapture()
        let count = queue.sync { output.index }
        print("Captured \(count) app-filtered frames")
        exit(count > 0 ? 0 : 2)
    } catch { fputs("\(error)\n", stderr); exit(2) }
}
RunLoop.main.run()
