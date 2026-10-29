// Appended to NotchView.swift by tools/sitefilm: films the real panel off screen.
//
// Real audio goes through the shipping analyser (AudioTap, 512-frame chunks at
// 48 kHz) and the real FerrofluidSim at the render clock's 60 Hz, and every frame
// is the real NotchRootView drawn by ImageRenderer at 2x. The colour field and the
// ink are integrated from the audio, never the wall clock, so a frame here is the
// frame the app would draw for that moment of the song. Only the media and
// controller are fixtures (title, cover, elapsed time, open or closed).
import AudioToolbox

@main @MainActor enum SiteFilm {
    static func main() {
        let a = CommandLine.arguments
        guard a.count >= 9, let data = FileManager.default.contents(atPath: a[1]),
              let cover = NSImage(contentsOfFile: a[3])
        else {
            FileHandle.standardError.write(Data(
                "usage: sitefilm AUDIO.f32 OUTDIR COVER TITLE ARTIST START DURATION SCRIPT [BG]\n".utf8))
            exit(1)
        }
        let out = URL(fileURLWithPath: a[2])
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let start = Double(a[6]) ?? 0, duration = Double(a[7]) ?? 240
        // SCRIPT: comma-separated "seconds:state", state one of open, closed, bare.
        let script = a[8].split(separator: ",").compactMap { cue -> (Double, String)? in
            let p = cue.split(separator: ":")
            guard p.count == 2, let t = Double(p[0]) else { return nil }
            return (t, String(p[1]))
        }
        let bg = a.count > 9 ? a[9] : "000000"
        let rgb = Int(bg, radix: 16) ?? 0
        let backdrop = Color(red: Double(rgb >> 16 & 255) / 255, green: Double(rgb >> 8 & 255) / 255,
                             blue: Double(rgb & 255) / 255)

        var samples = [Float](repeating: 0, count: data.count / 4)
        _ = samples.withUnsafeMutableBytes { data.copyBytes(to: $0) }
        let seconds = Double(samples.count) / 48000
        let ticks = levels(samples, ticks: Int(seconds * 60))

        let media = MediaManager()
        media.title = a[4]
        media.artist = a[5]
        media.artists = ArtistCredit.fallback(a[5], source: .music)
        media.artwork = cover
        media.palette = ArtworkPalette.extract(from: cover) ?? .fallback
        media.duration = duration
        media.isPlaying = true
        let controller = NotchController()
        controller.isMiniPlayerShown = true
        let fluid = FerrofluidSim()
        let width = ChromeRules.panelWidth + 120
        let height = controller.expandedSize.height + 40

        for frame in 0..<ticks.count {
            let t = Double(frame) / 60
            let state = script.last { $0.0 <= t }?.1 ?? "open"
            controller.isExpanded = state == "open"
            controller.isMiniPlayerShown = state != "bare"
            fluid.setOpen(controller.isExpanded)
            fluid.advance(levels: ticks[frame], dt: 1.0 / 60)
            media.position = start + t
            let view = ZStack(alignment: .top) {
                backdrop
                NotchRootView(controller: controller, media: media, fluid: fluid)
                    .frame(width: width, height: height, alignment: .top)
            }
            .frame(width: width, height: height)
            .environment(\.colorScheme, .dark)
            let renderer = ImageRenderer(content: view)
            renderer.scale = Double(ProcessInfo.processInfo.environment["SITEFILM_SCALE"] ?? "") ?? 2
            guard let image = renderer.cgImage else { exit(3) }
            let url = out.appendingPathComponent(String(format: "%05d.png", frame))
            guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)
            else { exit(4) }
            CGImageDestinationAddImage(dest, image, nil)
            CGImageDestinationFinalize(dest)
        }
    }

    /// The bands AudioLevels would publish on each 60 Hz tick (as in tools/fluidfilm).
    static func levels(_ samples: [Float], ticks: Int) -> [[Float]] {
        let tap = AudioTap()
        var result: [[Float]] = []
        var band = [Float](repeating: 0, count: AudioTap.bandCount)
        var samples = samples
        var offset = 0
        for tick in 1...max(1, ticks) {
            let due = min(samples.count, Int(Double(tick) / 60 * 48000))
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
