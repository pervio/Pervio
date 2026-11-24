import Foundation
import Vision
import AppKit

// The text inside the pictures that ship. A name in a screenshot is invisible to
// public_scan.py, which reads files as text — a rendered server list once carried
// a real user@host that way. This reads image paths on stdin and prints
// "PATH\tTEXT" per image (the recognised lines joined with " | "), using the
// system's text recognition, so scripts/make-public-tree.sh can search it.
// macOS only (Vision).
while let path = readLine() {
    guard let img = NSImage(contentsOfFile: path),
          let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
        print("\(path)\t<unreadable>")
        continue
    }
    let req = VNRecognizeTextRequest()
    req.recognitionLevel = .accurate
    req.recognitionLanguages = ["zh-Hans", "en-US"]
    req.usesLanguageCorrection = false
    let handler = VNImageRequestHandler(cgImage: cg, options: [:])
    do { try handler.perform([req]) } catch { print("\(path)\t<error \(error)>"); continue }
    let lines = (req.results ?? []).compactMap { $0.topCandidates(1).first?.string }
    print("\(path)\t\(lines.joined(separator: " | "))")
}
