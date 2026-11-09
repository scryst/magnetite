// filmocr: print the text macOS reads in each image, one line per file, so a film
// can be searched for what it should not show (counts, names, badges) before it ships.
// A frame it cannot read or OCR prints UNREADABLE or OCR-FAILED, is named on stderr,
// and makes it exit 1, so pipefail fails the check instead of passing an empty row.
//   ffmpeg -i film.mp4 -vf fps=15 /tmp/f/%04d.png && swiftc -O tools/filmocr.swift -o /tmp/filmocr
//   set -o pipefail; /tmp/filmocr /tmp/f/*.png | grep -E "[0-9]+ apps|@|Update"
import Foundation
import Vision
import ImageIO
var failed = 0
func fail(_ row: String) {
  print(row); FileHandle.standardError.write((row + "\n").data(using: .utf8)!); failed += 1
}
for p in CommandLine.arguments.dropFirst() {
  let name = (p as NSString).lastPathComponent
  guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: p) as CFURL, nil),
        let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { fail(name + "\tUNREADABLE"); continue }
  let r = VNRecognizeTextRequest(); r.recognitionLevel = .accurate; r.usesLanguageCorrection = false
  do { try VNImageRequestHandler(cgImage: cg).perform([r]) } catch { fail(name + "\tOCR-FAILED \(error)"); continue }
  let t = (r.results ?? []).compactMap { $0.topCandidates(1).first?.string }
  print(name + "\t| " + t.joined(separator: " | ") + " |")
}
if failed > 0 { FileHandle.standardError.write("filmocr: \(failed) frame(s) not read\n".data(using: .utf8)!); exit(1) }
