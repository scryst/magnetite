// Films the ink off screen: real audio through the shipping analyser, sim and view.
//
//   tools/fluidfilm AUDIO.f32 OUTDIR [seconds]
//
// AUDIO is raw mono float32 at 48 kHz. It is fed to the real AudioTap in 512-frame
// chunks, sampled at AudioLevels' 30 Hz, and stepped through FerrofluidSim at the
// render clock's 60 Hz, so a frame here is a frame the app would draw. Each frame is
// written as OUTDIR/NNNNN.png at 2x. No display, pointer, player or capture grant is
// involved, which makes before/after clips of a physics change exact: same audio,
// same frames, only the code differs.
import AudioToolbox
import Foundation
import SwiftUI

@main
enum FluidFilm {

    @MainActor
    static func main() {
        let args = CommandLine.arguments
        guard args.count >= 3, let data = FileManager.default.contents(atPath: args[1]) else {
            FileHandle.standardError.write(Data("usage: fluidfilm AUDIO.f32 OUTDIR [seconds]\n".utf8))
            exit(1)
        }
        let out = URL(fileURLWithPath: args[2])
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        var samples = [Float](repeating: 0, count: data.count / 4)
        _ = samples.withUnsafeMutableBytes { data.copyBytes(to: $0) }
        let seconds = args.count > 3 ? Double(args[3]) ?? 0 : Double(samples.count) / 48000
        let ticks = levels(samples, ticks: Int(seconds * 30))

        let sim = FerrofluidSim()
        let silence = [Float](repeating: 0, count: AudioTap.bandCount)
        sim.setOpen(true)
        for _ in 0..<90 { sim.advance(levels: silence, dt: 1.0 / 60) }

        let notch = CGSize(width: 185, height: 32)
        let panel = CGSize(width: ChromeRules.panelWidth, height: notch.height + ChromeRules.expandedBody)
        let tint = Color(red: 0.42, green: 0.55, blue: 0.95)
        // How many ink pixels changed since the last frame, one line per frame, so a
        // physics change can be measured as well as watched.
        var previous: [Bool] = []
        var motion = ""
        for frame in 0..<(ticks.count * 2) {
            sim.advance(levels: ticks[frame / 2], dt: 1.0 / 60)
            let view = ZStack(alignment: .top) {
                LinearGradient(colors: [Color(red: 0.10, green: 0.13, blue: 0.27),
                                        Color(red: 0.05, green: 0.06, blue: 0.13)],
                               startPoint: .top, endPoint: .bottom)
                FerrofluidView(sim: sim, notchSize: notch, panelSize: panel, openness: 1, tint: tint)
            }
            .frame(width: panel.width, height: panel.height)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            guard let image = renderer.cgImage else { exit(3) }
            let mask = inkMask(image)
            let changed = previous.isEmpty ? 0 : zip(mask, previous).filter { $0 != $1 }.count
            // The deepest ink row, in points: how far the body reaches into the panel.
            let lowest = (0..<image.height).last { row in
                (0..<image.width).contains { mask[row * image.width + $0] }
            } ?? 0
            let depth = Double(lowest + 1) / 2
            previous = mask
            motion += "\(frame) \(changed) " + String(format: "%.1f %.3f %.3f %.3f %.3f\n", depth, sim.swell, sim.impact,
                                                         sim.raised, sim.sites.map(\.height).max() ?? 0)
            let url = out.appendingPathComponent(String(format: "%05d.png", frame))
            guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)
            else { exit(4) }
            CGImageDestinationAddImage(dest, image, nil)
            CGImageDestinationFinalize(dest)
        }
        try? motion.write(to: out.appendingPathComponent("motion.txt"), atomically: true, encoding: .utf8)
    }

    /// Which pixels are ink: near black, where the panel behind it never is.
    static func inkMask(_ image: CGImage) -> [Bool] {
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8,
                                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return stride(from: 0, to: pixels.count, by: 4).map {
            pixels[$0] < 12 && pixels[$0 + 1] < 12 && pixels[$0 + 2] < 12
        }
    }

    /// The bands AudioLevels would publish on each 30 Hz tick.
    static func levels(_ samples: [Float], ticks: Int) -> [[Float]] {
        let tap = AudioTap()
        var result: [[Float]] = []
        var band = [Float](repeating: 0, count: AudioTap.bandCount)
        var samples = samples
        var offset = 0
        for tick in 1...max(1, ticks) {
            let due = min(samples.count, Int(Double(tick) / 30 * 48000))
            while offset + 512 <= due {
                samples.withUnsafeMutableBufferPointer { buf in
                    var abl = AudioBufferList(
                        mNumberBuffers: 1,
                        mBuffers: AudioBuffer(mNumberChannels: 1,
                                              mDataByteSize: UInt32(512 * MemoryLayout<Float>.size),
                                              mData: UnsafeMutableRawPointer(buf.baseAddress! + offset)))
                    withUnsafePointer(to: &abl) { tap.consume($0) }
                }
                offset += 512
            }
            tap.levels(into: &band)
            result.append(band)
        }
        return result
    }
}
