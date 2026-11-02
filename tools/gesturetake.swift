// One gesture loop for the site's journey: films the running Magnetite with the
// pointer drawn (NOTCHREC_CURSOR=1) while real pointer and trackpad events do one
// gesture, so the loop shown beside "Hover", "Drag" or "Swipe" is that gesture.
// Spotify is already playing; the pointer is put back where it was afterwards.
//
// usage: gesturetake hover|drag|swipe OUT.mov   (notchrec built next to this file)
import AppKit
import CoreGraphics

let notchX: CGFloat = 756
let panelMinX: CGFloat = 570, panelWidth: CGFloat = 372, seekY: CGFloat = 162 + 76
let film = (x: 556, y: 0, w: 400, h: 256, seconds: 7.0)

var t0 = 0.0
func now() -> Double { Date().timeIntervalSince1970 }
func mark(_ what: String) { print(String(format: "%.3f %@", now() - t0, what)); fflush(stdout) }
func wait(until t: Double) { while now() - t0 < t { usleep(2000) } }
func post(_ e: CGEvent?) { e?.post(tap: .cghidEventTap) }
func move(to p: CGPoint, dragging: Bool = false) {
    post(CGEvent(mouseEventSource: nil, mouseType: dragging ? .leftMouseDragged : .mouseMoved,
                 mouseCursorPosition: p, mouseButton: .left))
}
func glide(from a: CGPoint, to b: CGPoint, over d: Double, dragging: Bool = false) {
    let steps = max(1, Int(d * 120)), start = now()
    for i in 1...steps {
        let u = Double(i) / Double(steps), e = u < 0.5 ? 2 * u * u : 1 - pow(-2 * u + 2, 2) / 2
        move(to: CGPoint(x: a.x + (b.x - a.x) * e, y: a.y + (b.y - a.y) * e), dragging: dragging)
        while now() - start < d * u { usleep(1000) }
    }
}
func swipe(dx total: Double, over d: Double) {
    func scroll(_ dx: Int32, phase: Int64) {
        let e = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: 0, wheel2: dx, wheel3: 0)
        e?.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        e?.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
        e?.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: Int64(dx))
        post(e)
    }
    scroll(0, phase: 1)
    let steps = 14
    for i in 0..<steps {
        let w = sin(Double.pi * (Double(i) + 0.5) / Double(steps)) * Double.pi / 2 / Double(steps)
        scroll(Int32((total * w).rounded()), phase: 2)
        usleep(useconds_t(d / Double(steps) * 1e6))
    }
    scroll(0, phase: 4)
}
func seekPoint(_ f: CGFloat) -> CGPoint { CGPoint(x: panelMinX + panelWidth * f, y: seekY) }

let args = CommandLine.arguments
guard args.count == 3, ["hover", "drag", "swipe"].contains(args[1]) else {
    FileHandle.standardError.write(Data("usage: gesturetake hover|drag|swipe OUT.mov\n".utf8)); exit(1)
}
let mode = args[1]
let home = CGEvent(source: nil)?.location ?? CGPoint(x: notchX, y: 500)
// Below the film's frame: the open panel fills the frame, so the pointer comes in
// from under it and leaves the same way, and the panel folds once it has gone.
let rest = CGPoint(x: notchX + 70, y: 320), top = CGPoint(x: notchX, y: 14), middle = CGPoint(x: notchX + 40, y: 90)
move(to: rest)
if mode != "hover" { glide(from: rest, to: top, over: 0.45); glide(from: top, to: middle, over: 0.4) }
usleep(1_200_000)

setenv("NOTCHREC_CURSOR", "1", 1)
let rec = Process()
rec.executableURL = URL(fileURLWithPath: args[0]).deletingLastPathComponent().appendingPathComponent("notchrec")
rec.arguments = [args[2], "\(film.seconds)", "\(film.x)", "\(film.y)", "\(film.w)", "\(film.h)"]
let pipe = Pipe()
rec.standardOutput = pipe
try rec.run()
var buffer = ""
while !buffer.contains("first-frame") {
    buffer += String(decoding: pipe.fileHandleForReading.availableData, as: UTF8.self)
}
t0 = Double(buffer.split(separator: " ")[1].split(separator: "\n")[0]) ?? now()
mark("first-frame")

switch mode {
case "hover":
    // In, open, a beat, out, and the panel folds while the pointer waits where it began.
    wait(until: 1.0); mark("in"); glide(from: rest, to: top, over: 0.5)
    glide(from: top, to: middle, over: 0.35)
    wait(until: 3.0); mark("out"); glide(from: middle, to: rest, over: 0.45)
case "drag":
    wait(until: 1.0); glide(from: middle, to: seekPoint(0.2), over: 0.45)
    wait(until: 1.6); mark("press")
    post(CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: seekPoint(0.2), mouseButton: .left))
    glide(from: seekPoint(0.2), to: seekPoint(0.62), over: 1.2, dragging: true)
    wait(until: 3.0); mark("release")
    post(CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: seekPoint(0.62), mouseButton: .left))
    wait(until: 3.3); glide(from: seekPoint(0.62), to: middle, over: 0.5)
default:
    wait(until: 1.5); mark("swipe"); swipe(dx: -120, over: 0.22); mark("swipe-end")
}
rec.waitUntilExit()
mark("done \(rec.terminationStatus)")
move(to: home)
exit(rec.terminationStatus)
