// filmocr: print the text macOS reads in each image, one line per file, so a film
// can be searched for what it should not show (counts, names, badges) before it ships.
//   ffmpeg -i film.mp4 -vf fps=15 /tmp/f/%04d.png && swiftc -O tools/filmocr.swift -o /tmp/filmocr
//   /tmp/filmocr /tmp/f/*.png | grep -E "[0-9]+ apps|@|Update"
import Foundation
import Vision
import ImageIO
for p in CommandLine.arguments.dropFirst() {
  guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: p) as CFURL, nil),
        let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { print(p + "\tUNREADABLE"); continue }
  let r = VNRecognizeTextRequest(); r.recognitionLevel = .accurate; r.usesLanguageCorrection = false
  try? VNImageRequestHandler(cgImage: cg).perform([r])
  let t = (r.results ?? []).compactMap { $0.topCandidates(1).first?.string }
  print((p as NSString).lastPathComponent + "\t| " + t.joined(separator: " | ") + " |")
}
