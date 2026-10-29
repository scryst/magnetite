import AppKit
import SwiftUI

/// Colours pulled from album art, used to drive the ambient mesh glow.
///
/// Downsamples hard, buckets pixels by hue, then ranks buckets by how much
/// colour they carry. Cheap enough to run on every track change.
struct ArtworkPalette: Equatable, Sendable {
    var colors: [Color]
    /// Mean luminance of the whole image, 0...1.
    var luminance: Double
    /// Gamma-encoded sRGB channels of the brightest colour painted into the
    /// wash, by true relative luminance.
    ///
    /// This differs from `luminance`: the bucket pass discards greys, so a dark
    /// sleeve with one neon element has a low mean but a bright wash. Contrast
    /// rules must key off what is on screen. Kept as channels because contrast
    /// is not a function of any scalar; two colours with the same weighted
    /// channel sum can emit 1.6x different light.
    var washPeak: Peak
    /// The sleeve had no colour of its own (black-and-white art), so `colors` is the
    /// app's own lustre rather than anything taken from the cover.
    var monochrome = false

    /// One wash colour as gamma-encoded sRGB.
    struct Peak: Equatable, Sendable {
        var r: Double
        var g: Double
        var b: Double
    }

    /// Ceiling on the true relative luminance of any wash colour: the light a
    /// neutral at gamma-encoded 0.46 emits.
    ///
    /// `spread` pushes colours apart and one offset multiplies brightness by
    /// 1.18, so without a ceiling a vivid accent could paint the field at full
    /// brightness and leave white type under 2:1. Capping luminance rather than
    /// adding scrim keeps hue and chroma.
    ///
    /// The bound is in true luminance because encoded values cannot bound light:
    /// pure magenta is 0.2848 encoded yet emits 1.6x the light of the neutral.
    /// In true units the neutral is the worst case (a saturated colour of equal
    /// luminance composes darker under the scrim), so one bound covers every
    /// colour.
    static let washLuminanceCeiling = relativeLuminance(encoded: 0.46)

    /// The scrim laid over the wash behind the type, as an alpha. `depth` is 0
    /// at the panel's top edge and 1 at its foot.
    ///
    /// Lives here rather than in the view so `palettecheck`, which compiles
    /// against this file alone, tests the real values.
    ///
    /// It deliberately ignores the wash's luminance: `capped()` already pins
    /// every colourful palette to the ceiling, and a luminance term made a
    /// brighter record produce a darker panel past l = 0.42. With a constant
    /// scrim the field stays proportional to the wash.
    ///
    /// Retracted, the band must read as an extension of the cutout's black, so
    /// it takes the heavier `retractedScrim`; opening is where the record's
    /// colour is allowed to show.
    static func scrimAlpha(depth: Double = 0, expanded: Bool = true) -> Double {
        guard expanded else { return retractedScrim }
        return scrimHead + (scrimFoot - scrimHead) * min(1, max(0, depth))
    }
    /// Scrim alpha at the head and foot of the open panel. White type over the
    /// worst legal wash (the neutral at the ceiling) measures 7.80:1 at the head
    /// and 9.73:1 at the foot, comfortably over WCAG AA.
    static let scrimHead = 0.30
    static let scrimFoot = 0.42
    /// Scrim for the closed band, a flat value because the band is only a couple
    /// of dozen points tall.
    static let retractedScrim = 0.62

    /// White type's WCAG contrast ratio over the composited field.
    ///
    /// The black scrim composites per channel in gamma space, which is where
    /// SwiftUI blends (checked to within 2/255), and each channel is linearised
    /// before the luminance weights are applied. The order matters: the sRGB
    /// curve is convex, so linearising the weighted sum understates the field
    /// and inflates the ratio on saturated covers (12.67:1 reported over a
    /// magenta field that truly offers 5.91:1). Greys agree under every order,
    /// so a grey test point cannot catch it.
    static func titleContrast(over peak: Peak, depth: Double = 0) -> Double {
        1.05 / (fieldLuminance(under: peak, depth: depth) + 0.05)
    }

    /// The light the scrimmed field emits behind the type.
    static func fieldLuminance(under peak: Peak, depth: Double = 0,
                               expanded: Bool = true) -> Double {
        let keep = 1 - scrimAlpha(depth: depth, expanded: expanded)
        return relativeLuminance(of: Peak(r: peak.r * keep,
                                          g: peak.g * keep,
                                          b: peak.b * keep))
    }

    /// Chrome-tier type (the band clocks, the idle card) over the same field.
    /// Translucent white composites in gamma space like everything else.
    static func chromeContrast(over peak: Peak, depth: Double = 0) -> Double {
        let keep = 1 - scrimAlpha(depth: depth)
        let a = chromeTypeAlpha
        let type = Peak(r: a + (1 - a) * peak.r * keep,
                        g: a + (1 - a) * peak.g * keep,
                        b: a + (1 - a) * peak.b * keep)
        return (relativeLuminance(of: type) + 0.05)
            / (fieldLuminance(under: peak, depth: depth) + 0.05)
    }

    /// Opacity of the chrome text tier. 0.74 clears 4.5:1 over the worst legal
    /// wash (0.62 gave 3.63:1) while staying below the 0.76 of the artist line,
    /// so the type ranks still read.
    static let chromeTypeAlpha = 0.74

    /// The no-artwork wash, run through the same `capped()` rule as every
    /// extracted palette.
    ///
    /// The seed colours are hand-picked; `washPeak` is computed from the capped
    /// result, so it cannot drift from the colours.
    static let fallback: ArtworkPalette = {
        let seed: [(r: Double, g: Double, b: Double)] = [
            (0.18, 0.55, 0.62),
            (0.10, 0.32, 0.44),
            (0.28, 0.24, 0.52),
            (0.08, 0.18, 0.28),
        ]
        let hsb = capped(seed.map { rgbToHSB($0.r, $0.g, $0.b) })
        return ArtworkPalette(colors: hsb.map(Self.color),
                              // Mean of the seeds, as `extract` reports it.
                              luminance: 0.22,
                              washPeak: Self.peak(of: hsb))
    }()

    /// `nil` when the image can't be rasterised, so callers keep their previous
    /// palette rather than flashing to the fallback.
    static func extract(from image: NSImage) -> ArtworkPalette? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return nil }

        let w = 24, h = 24
        // CGContext keeps the buffer pointer and writes through it on every
        // `draw`, so it must come from `withUnsafeMutableBytes`; a pointer made
        // with `&` is only valid for the duration of the initialiser call.
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let drawn: Bool = pixels.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress,
                                      width: w, height: h,
                                      bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return nil }

        // 12 hue buckets, saturated pixels only: greys carry no identity and
        // would pull every palette toward the same muddy centre.
        var buckets = [(r: Double, g: Double, b: Double, weight: Double)](
            repeating: (0, 0, 0, 0), count: 12)
        var lumaSum = 0.0
        var counted = 0.0
        // Mean colour, greys included. It is the only description of a
        // monochrome sleeve, which the bucket pass discards.
        var rSum = 0.0, gSum = 0.0, bSum = 0.0
        // Every pixel's luma, for a monochrome sleeve's light: where a black-and-white
        // cover differs from another is how much of it is dark, lit, or in between.
        var lumas: [Double] = []

        for i in stride(from: 0, to: pixels.count, by: 4) {
            let a = Double(pixels[i + 3]) / 255
            guard a > 0.35 else { continue }
            let r = Double(pixels[i]) / 255
            let g = Double(pixels[i + 1]) / 255
            let b = Double(pixels[i + 2]) / 255

            let luma = 0.2126 * r + 0.7152 * g + 0.0722 * b
            lumaSum += luma
            lumas.append(luma)
            rSum += r; gSum += g; bSum += b
            counted += 1

            let maxC = max(r, g, b), minC = min(r, g, b)
            let delta = maxC - minC
            guard delta > 0.08 else { continue }        // skip greys

            var hue: Double
            if maxC == r { hue = (g - b) / delta }
            else if maxC == g { hue = 2 + (b - r) / delta }
            else { hue = 4 + (r - g) / delta }
            hue = (hue / 6).truncatingRemainder(dividingBy: 1)
            if hue < 0 { hue += 1 }

            let idx = min(11, Int(hue * 12))
            // Weight by saturation and brightness so a vivid mid-tone beats both
            // a pastel and a near-black of the same hue.
            let weight = delta * (0.35 + maxC * 0.65)
            buckets[idx].r += r * weight
            buckets[idx].g += g * weight
            buckets[idx].b += b * weight
            buckets[idx].weight += weight
        }

        let ranked = buckets
            .filter { $0.weight > 0.0001 }
            .sorted { $0.weight > $1.weight }
            .prefix(4)
            .map { (r: $0.r / $0.weight, g: $0.g / $0.weight, b: $0.b / $0.weight) }

        let mean = counted > 0 ? lumaSum / counted : 0.2

        // A greyscale sleeve has no bucket above the saturation floor. Returning
        // nil would leave the previous song's colour on screen, so answer with a
        // monochrome palette instead.
        guard !ranked.isEmpty else {
            guard counted > 0 else { return nil }
            // The sleeve's own light: four tones from its luma distribution, so a
            // near-black cover with one lit word and a bright grey photograph give
            // different fields. Stretched to a spread of at least 0.35 about the median,
            // because a flat sleeve's real tones are too close together for the moving
            // mesh to show anything, which is what made such covers look dead.
            lumas.sort()
            func tone(_ q: Double) -> Double { lumas[min(lumas.count - 1, Int(q * Double(lumas.count)))] }
            let median = tone(0.5)
            var lo = tone(0.05), hi = tone(0.95)
            let span = hi - lo
            if span < 0.45 {
                lo = min(max(0.05, median - 0.12), 0.5)
                hi = lo + 0.45
            }
            // Where each tone sits between `lo` and `hi`: the sleeve's own spacing when it
            // has a real spread, even spacing as it flattens, so a near-uniform sleeve
            // still gets a highlight to move instead of four copies of one grey.
            func stretched(_ q: Double) -> Double {
                let own = min(1, max(0, (tone(q) - tone(0.05)) / max(0.001, span)))
                let trust = min(1, span / 0.45)
                return lo + (hi - lo) * (own * trust + q * (1 - trust))
            }
            // A sepia or blue-washed print keeps its cast, raised so it shows. A true
            // grey gets a cool metallic sheen; its mean hue is JPEG noise, and taking it
            // drew a green line under a black-and-white cover.
            let cast = rgbToHSB(rSum / counted, gSum / counted, bSum / counted)
            let tinted = cast.s >= 0.04
            let hue = tinted ? cast.h : 0.6
            let chroma = tinted ? min(0.24, cast.s * 2.5) : 0.07
            let hsb = capped([(h: hue, s: chroma * 0.6, b: stretched(0.95)),
                              (h: hue, s: chroma, b: stretched(0.25)),
                              (h: hue, s: chroma * 1.2, b: stretched(0.65)),
                              (h: hue, s: chroma * 0.8, b: stretched(0.05))])
            return ArtworkPalette(colors: hsb.map(Self.color),
                                  luminance: mean,
                                  washPeak: Self.peak(of: hsb),
                                  monochrome: true)
        }

        let hsb = capped(spread(ranked))
        return ArtworkPalette(colors: hsb.map(Self.color),
                              luminance: mean,
                              washPeak: Self.peak(of: hsb))
    }

    /// Internal so palettecheck can walk the reachable colour set through the
    /// real pipeline.
    typealias HSB = (h: Double, s: Double, b: Double)

    private static func color(_ e: HSB) -> Color {
        Color(hue: e.h, saturation: e.s, brightness: e.b)
    }

    /// Relative luminance of a gamma-encoded grey level, per WCAG: linearise,
    /// then weight. Encoded and linear values share a numeral but not a scale
    /// (0.1833 encoded is sRGB 47/255; 0.1833 of luminance is 118/255).
    static func relativeLuminance(encoded v: Double) -> Double {
        v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
    }

    /// Relative luminance of a colour: linearise each channel, then weight.
    /// The two steps do not commute; see `titleContrast`.
    static func relativeLuminance(of p: Peak) -> Double {
        0.2126 * relativeLuminance(encoded: p.r)
            + 0.7152 * relativeLuminance(encoded: p.g)
            + 0.0722 * relativeLuminance(encoded: p.b)
    }

    private static func channels(of e: HSB) -> Peak {
        let c = NSColor(hue: e.h, saturation: e.s, brightness: e.b, alpha: 1)
            .usingColorSpace(.sRGB) ?? .black
        return Peak(r: Double(c.redComponent),
                    g: Double(c.greenComponent),
                    b: Double(c.blueComponent))
    }

    private static func peak(of hsb: [HSB]) -> Peak {
        hsb.map(channels(of:))
            .max { relativeLuminance(of: $0) < relativeLuminance(of: $1) }
            ?? Peak(r: 0.2, g: 0.2, b: 0.2)
    }

    /// Pulls every colour under the luminance ceiling without changing hue.
    ///
    /// Luminance is not linear in the brightness scale (power curve with an
    /// offset, plus the saturation boost in `dimmed`), so the scale is found by
    /// bisection. The function is monotone in the scale, so bisection converges
    /// from the safe side.
    ///
    /// Internal so palettecheck walks the app's own colour set; an independent
    /// ruler over a different set would prove nothing about what is painted.
    static func capped(_ hsb: [HSB]) -> [HSB] {
        hsb.map { entry in
            guard relativeLuminance(of: channels(of: entry)) > washLuminanceCeiling
            else { return entry }
            var lo = 0.0, hi = 1.0
            for _ in 0..<28 {
                let mid = (lo + hi) / 2
                if relativeLuminance(of: channels(of: dimmed(entry, scale: mid)))
                    > washLuminanceCeiling {
                    hi = mid
                } else {
                    lo = mid
                }
            }
            return dimmed(entry, scale: lo)
        }
    }

    /// Darkens a colour while raising its saturation.
    ///
    /// Scaling brightness alone keeps the saturation number but loses most of
    /// the perceived chroma, so pale covers turn muddy. Real dark colours are
    /// more saturated than their light counterparts.
    private static func dimmed(_ e: HSB, scale: Double) -> HSB {
        (e.h, min(1, e.s * (1 + (1 - scale) * 1.15)), min(1, e.b * scale))
    }

    /// Guarantees four visibly different colours.
    ///
    /// A near-monochrome cover yields four near-identical colours, leaving the
    /// animated gradient nothing to animate between. Where the source lacks
    /// variation, derive it by rotating hue and spreading brightness.
    private static func spread(_ found: [(r: Double, g: Double, b: Double)]) -> [HSB] {
        var hsb = found.map { rgbToHSB($0.r, $0.g, $0.b) }

        // Anchor on the strongest colour and fan the rest out around it.
        let base = hsb[0]
        let offsets: [(h: Double, s: Double, b: Double)] = [
            (0.00, 1.00, 1.00),
            (0.085, 0.92, 0.72),
            (-0.075, 1.00, 1.18),
            (0.16, 0.80, 0.52),
        ]

        for i in 0..<4 {
            let want = offsets[i]
            // Keep a genuinely distinct extracted colour; synthesise otherwise.
            let existing = i < hsb.count ? hsb[i] : nil
            // At i == 0 `existing` is `base`, so this is false and slot 0 always
            // takes the synthesised branch (`base` with the floors applied).
            let distinct = existing.map { hueDistance($0.h, base.h) > 0.05 } ?? false
            if distinct, let e = existing {
                hsb[i] = (e.h, min(1, max(0.42, e.s)), min(1, max(0.20, e.b)))
            } else {
                let h = (base.h + want.h).truncatingRemainder(dividingBy: 1)
                let entry = (h < 0 ? h + 1 : h,
                             min(1, max(0.45, base.s * want.s)),
                             min(1, max(0.18, base.b * want.b)))
                if i < hsb.count { hsb[i] = entry } else { hsb.append(entry) }
            }
        }

        // Always four entries: `found` is already `.prefix(4)` and the loop
        // only appends when an index is missing.
        return hsb
    }

    private static func hueDistance(_ a: Double, _ b: Double) -> Double {
        let d = abs(a - b).truncatingRemainder(dividingBy: 1)
        return min(d, 1 - d)
    }

    private static func rgbToHSB(_ r: Double, _ g: Double, _ b: Double)
        -> (h: Double, s: Double, b: Double) {
        let maxC = max(r, g, b), minC = min(r, g, b)
        let delta = maxC - minC
        var h = 0.0
        if delta > 0.0001 {
            if maxC == r { h = (g - b) / delta }
            else if maxC == g { h = 2 + (b - r) / delta }
            else { h = 4 + (r - g) / delta }
            h = (h / 6).truncatingRemainder(dividingBy: 1)
            if h < 0 { h += 1 }
        }
        return (h, maxC > 0 ? delta / maxC : 0, maxC)
    }
}
