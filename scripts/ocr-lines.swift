// OCR helper for the ghost-position E2E: prints one JSON object per recognized text line of
// the given image, with the Vision-normalized bounding box (bottom-left origin, [0,1]).
// Build: swiftc -O scripts/ocr-lines.swift -o /tmp/cotabby-ocr-lines
// Usage: /tmp/cotabby-ocr-lines <image.png>
import Foundation
import ImageIO
import Vision

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: ocr-lines <image>\n".utf8))
    exit(2)
}
let url = URL(fileURLWithPath: CommandLine.arguments[1])
guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
    FileHandle.standardError.write(Data("cannot read image\n".utf8))
    exit(1)
}

let request = VNRecognizeTextRequest()
request.recognitionLevel = .accurate
request.usesLanguageCorrection = false
try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])

for observation in request.results ?? [] {
    guard let candidate = observation.topCandidates(1).first else { continue }
    let box = observation.boundingBox
    let record: [String: Any] = [
        "text": candidate.string,
        "x": box.minX, "y": box.minY, "w": box.width, "h": box.height
    ]
    let data = try JSONSerialization.data(withJSONObject: record)
    print(String(data: data, encoding: .utf8)!)
}
