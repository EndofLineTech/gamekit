import Foundation
import Vision

// Separate process so the observation harness can terminate stalled OCR.
// Output stays local and is never included in public game evidence.
struct ScreenText: Encodable {
    let text: String
    let boundingBox: CGRect
}

guard CommandLine.arguments.count == 2 || CommandLine.arguments.count == 3 else { exit(2) }
let request = VNRecognizeTextRequest()
request.recognitionLevel = .accurate
let roi: CGRect
switch CommandLine.arguments.count == 3 ? CommandLine.arguments[2] : "full" {
case "full": roi = CGRect(x: 0, y: 0, width: 1, height: 1)
case "next-button": roi = CGRect(x: 0.30, y: 0.10, width: 0.25, height: 0.20)
case "brightness": roi = CGRect(x: 0.75, y: 0.20, width: 0.20, height: 0.15)
case "satisfactory":
    roi = CGRect(x: 0, y: 0, width: 1, height: 1)
    request.recognitionLevel = .fast
default: exit(2)
}
request.regionOfInterest = roi
try VNImageRequestHandler(url: URL(fileURLWithPath: CommandLine.arguments[1])).perform([request])
let observations = (request.results ?? []).map { observation in
    let box = observation.boundingBox
    return ScreenText(text: observation.topCandidates(1).first?.string ?? "",
        boundingBox: CGRect(x: roi.minX + roi.width * box.minX, y: roi.minY + roi.height * box.minY,
                            width: roi.width * box.width, height: roi.height * box.height))
}
FileHandle.standardOutput.write(try JSONEncoder().encode(observations))
