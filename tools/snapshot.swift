// Appended to NotchView.swift by tools/snapshot so the real private pieces render.
// Fixtures only: no windows, player observations, Apple Events or network access.
@main @MainActor enum Snapshot {
    static func save<V: View>(_ name: String, _ view: V, width: CGFloat, height: CGFloat) {
        let renderer = ImageRenderer(content: view
            .frame(width: width, height: height, alignment: .top)
            .environment(\.colorScheme, .dark))
        renderer.scale = 2
        guard let image = renderer.cgImage,
              let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
        else { fatalError("could not render \(name)") }
        print("SNAPSHOT \(name) \(png.base64EncodedString())")
        if name.hasPrefix("artwork-") {
            let bitmap = NSBitmapImageRep(cgImage: image)
            let y = name == "artwork-large" ? 32 : 16
            let edge = bitmap.colorAt(x: image.width / 2, y: y)!.usingColorSpace(.deviceRGB)!
            let printColor = bitmap.colorAt(x: image.width / 2, y: y + 4)!.usingColorSpace(.deviceRGB)!
            let difference = abs(edge.redComponent - printColor.redComponent)
                + abs(edge.greenComponent - printColor.greenComponent)
                + abs(edge.blueComponent - printColor.blueComponent)
            print("RENDER_CHECK \(name)-printFillsTile \(difference < 0.08)")
        }
    }

    static func main() {
        Motion.reduceMotion = true
        let media = MediaManager()
        let controller = NotchController()
        let fluid = FerrofluidSim()
        let cover = NSImage(size: NSSize(width: 88, height: 88), flipped: false) { rect in
            NSColor(calibratedRed: 0.72, green: 0.36, blue: 0.17, alpha: 1).setFill()
            rect.fill()
            NSColor(calibratedRed: 0.96, green: 0.76, blue: 0.45, alpha: 1).setFill()
            NSBezierPath(ovalIn: NSRect(x: 17, y: 17, width: 54, height: 54)).fill()
            return true
        }
        media.artwork = cover
        controller.liveActivity = .isPlaying
        save("closed-on", NotchRootView(controller: controller, media: media, fluid: fluid),
             width: 420, height: 60)
        // Same time and palette, different audio shape: only the old camera
        // boundary should change. The generated cover is identical in both runs.
        fluid.sites = fluid.sites.map { s in
            var changed = s; changed.height = 1 - s.height; return changed
        }
        fluid.swell = 0.1
        save("closed-on-other-beat", NotchRootView(controller: controller, media: media, fluid: fluid),
             width: 420, height: 60)
        controller.menuBarHeight = 32
        save("closed-no-sliver", NotchRootView(controller: controller, media: media, fluid: fluid),
             width: 420, height: 60)
        controller.menuBarHeight = 33
        for (name, position) in [("closed-start", 0.0), ("closed-end", 240.0)] {
            media.position = position
            save(name, NotchRootView(controller: controller, media: media, fluid: fluid),
                 width: 420, height: 60)
        }
        media.position = 115
        controller.liveActivity = .none
        save("closed-off", NotchRootView(controller: controller, media: media, fluid: fluid),
             width: 420, height: 60)
        controller.isExpanded = true
        save("expanded", NotchRootView(controller: controller, media: media, fluid: fluid),
             width: 420, height: 190)
        media.artist = "Aria North, Beck Rivers & Cleo Summer"
        media.artists = ArtistCredit.fallback(media.artist, source: .music)
        save("expanded-long-credits", NotchRootView(controller: controller, media: media, fluid: fluid),
             width: 420, height: 190)
        save("artwork-large", Artwork(image: cover, palette: .fallback, size: 88, radius: 14)
            .padding(16), width: 120, height: 120)
        save("artwork-small", Artwork(image: cover, palette: .fallback, size: 19, radius: 5.5)
            .padding(8), width: 35, height: 35)
    }
}
