// Reads the text in each image listed (one absolute path per line in the file named by the first argument) with the system's Vision text recognizer and
// prints one JSON object per image: {"path": ..., "text": ...}. Used only by scripts/scan-repository.py --images to look for an e-mail address, a
// name or a session value shown in a screenshot. Read-only: it opens each image and writes nothing.
import Foundation
import Vision
import ImageIO

guard CommandLine.arguments.count == 2, let listing = try? String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8) else {
    FileHandle.standardError.write(Data("usage: ocr-images.swift LISTFILE\n".utf8)); exit(64)
}
for path in listing.split(separator: "\n").map(String.init) {
    var text = ""
    if let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        try? VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }
    let object: [String: String] = ["path": path, "text": text]
    if let data = try? JSONSerialization.data(withJSONObject: object), let line = String(data: data, encoding: .utf8) { print(line) }
}
