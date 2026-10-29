// One take of the site film: films the running Magnetite with notchrec while real
// pointer and trackpad events play it, so every frame is the shipping app answering
// real input. Open under the pointer, two fingers swipe to skip, the seek edge is
// dragged, the pointer leaves so the panel folds, and returns to open it again.
//
// Events are posted at the HID level, which needs the Accessibility grant, and the
// pointer is put back where it was afterwards. Each event's time, relative to the
// film's first frame, is printed so the song can be laid under the picture.
//
// usage: notchtake OUT.mov   (notchrec built next to this file)
import AppKit
import CoreGraphics

let notchX: CGFloat = 756
// The open panel's drawn shell, in points from the display's top-left.
let panelMinX: CGFloat = 570, panelWidth: CGFloat = 372, seekY: CGFloat = 162
let film = (x: 556, y: 0, w: 400, h: 175, seconds: 18.0)

var t0 = 0.0
func now() -> Double { Date().timeIntervalSince1970 }
func mark(_ what: String) { print(String(format: "%.3f %@", now() - t0, what)); fflush(stdout) }
func wait(until t: Double) { while now() - t0 < t { usleep(2000) } }

func post(_ e: CGEvent?) { e?.post(tap: .cghidEventTap) }
func move(to p: CGPoint, dragging: Bool = false) {
    post(CGEvent(mouseEventSource: nil, mouseType: dragging ? .leftMouseDragged : .mouseMoved,
                 mouseCursorPosition: p, mouseButton: .left))
}
/// A hand's glide: eased, at 120 Hz, from wherever the pointer is.
func glide(from a: CGPoint, to b: CGPoint, over d: Double, dragging: Bool = false) {
    let steps = max(1, Int(d * 120)), start = now()
    for i in 1...steps {
        let u = Double(i) / Double(steps), e = u < 0.5 ? 2 * u * u : 1 - pow(-2 * u + 2, 2) / 2
        move(to: CGPoint(x: a.x + (b.x - a.x) * e, y: a.y + (b.y - a.y) * e), dragging: dragging)
        while now() - start < d * u { usleep(1000) }
    }
}
/// Two fingers across the trackpad: a continuous, phased scroll with no momentum,
/// which is what `NotchGestures` reads as a swipe.
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
        // Faster in the middle, as a finger moves.
        let w = sin(Double.pi * (Double(i) + 0.5) / Double(steps)) * Double.pi / 2 / Double(steps)
        scroll(Int32((total * w).rounded()), phase: 2)
        usleep(useconds_t(d / Double(steps) * 1e6))
    }
    scroll(0, phase: 4)
}
func seekPoint(_ f: CGFloat) -> CGPoint { CGPoint(x: panelMinX + panelWidth * f, y: seekY) }

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: notchtake OUT.mov\n".utf8)); exit(1)
}
let home = CGEvent(source: nil)?.location ?? CGPoint(x: notchX, y: 500)
let rest = CGPoint(x: notchX, y: 420), top = CGPoint(x: notchX, y: 14), middle = CGPoint(x: notchX, y: 80)
// The film opens and loops on the open panel, so its poster is a frame of it.
move(to: rest)
glide(from: rest, to: top, over: 0.45)
usleep(1_500_000)

let rec = Process()
rec.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
    .appendingPathComponent("notchrec")
rec.arguments = [CommandLine.arguments[1], "\(film.seconds)", "\(film.x)", "\(film.y)", "\(film.w)", "\(film.h)"]
let pipe = Pipe()
rec.standardOutput = pipe
try rec.run()
// The film's clock starts at its first frame, which notchrec prints.
var buffer = ""
while !buffer.contains("first-frame") {
    buffer += String(decoding: pipe.fileHandleForReading.availableData, as: UTF8.self)
}
t0 = Double(buffer.split(separator: " ")[1].split(separator: "\n")[0]) ?? now()
mark(String(format: "first-frame %.3f", t0))

wait(until: 2.4); mark("swipe"); swipe(dx: -120, over: 0.22); mark("swipe-end")
wait(until: 4.4); glide(from: top, to: seekPoint(0.03), over: 0.6)
wait(until: 5.2); mark("press")
post(CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: seekPoint(0.03), mouseButton: .left))
glide(from: seekPoint(0.03), to: seekPoint(0.62), over: 1.5, dragging: true)
wait(until: 7.0); mark("release")
post(CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: seekPoint(0.62), mouseButton: .left))
wait(until: 7.6); glide(from: seekPoint(0.62), to: middle, over: 0.6)
wait(until: 10.6); mark("leave"); glide(from: middle, to: rest, over: 0.4)
wait(until: 14.2); mark("hover"); glide(from: rest, to: top, over: 0.45)
rec.waitUntilExit()
mark("done \(rec.terminationStatus)")
move(to: home)
exit(rec.terminationStatus)
