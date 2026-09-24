import AppKit
import SwiftUI

/// Colours pulled from album art, used to drive the ambient mesh glow.
///
/// The original leans on the `DominantColors` package. This is a small
/// self-contained equivalent: downsample hard, bucket in hue space, then rank by
/// how much colour a bucket actually carries. Cheap enough to run on every track
/// change without a frame drop.
struct ArtworkPalette: Equatable, Sendable {
    var colors: [Color]
    /// Mean luminance of the whole image, 0...1. Dark art needs a lift to stay
    /// legible on black.
    var luminance: Double
    /// Gamma-encoded sRGB channels of the brightest colour actually painted
    /// into the wash — brightest by true relative luminance.
    ///
    /// Not the same thing as `luminance`, and the difference is the whole point:
    /// the bucket pass throws greys away, so a dark sleeve with one neon element
    /// has a low mean and a blazing wash. Anything protecting the type has to
    /// key off what is on screen, not off the average of the cover. Carried as
    /// channels rather than one number because contrast is not a function of
    /// any scalar: two colours with the same weighted channel sum can differ by
    /// 1.6x in the light they emit, which is exactly the gap that let a magenta
    /// wash through a gate tuned on a neutral.
    var washPeak: Peak

    /// One wash colour as gamma-encoded sRGB, the form every rule below takes.
    struct Peak: Equatable, Sendable {
        var r: Double
        var g: Double
        var b: Double
    }

    /// TRUE-relative-luminance ceiling for any wash colour: the light a neutral
    /// at gamma-encoded 0.46 emits — the old ceiling, restated in honest units.
    ///
    /// `spread` deliberately pushes colours apart, and one of its offsets
    /// multiplies brightness by 1.18 — with only a floor and a ceiling of 1.0, a
    /// vivid accent could legally paint the field at full brightness and leave
    /// white type at under 2:1. Capping luminance rather than piling on more
    /// scrim keeps hue and chroma, so the shell still wears the record's colour
    /// instead of a grey veil.
    ///
    /// The fence used to be drawn in encoded units, and encoded units cannot
    /// bound light: pure magenta measures 0.2848 on that scale, comfortably
    /// "under" an encoded 0.46, while emitting 1.6x the light of the neutral
    /// sitting exactly on it. Every scrim constant was tuned against the
    /// neutral, so the fence admitted colours the guarantee was never sized
    /// for — white type over a legal magenta wash measured 5.48:1 against a
    /// bar of 7. In true units the neutral IS the worst case: at equal
    /// luminance a saturated colour composes darker under the scrim, so one
    /// bound covers every colour and the scrim numbers did not have to move.
    static let washLuminanceCeiling = relativeLuminance(encoded: 0.46)

    /// The scrim laid over the wash behind the type, as an alpha, with `depth`
    /// 0 at the panel's top edge and 1 at its foot.
    ///
    /// Lives here rather than in the view because `palettecheck` compiles against
    /// this file alone: written as a literal in NotchView it was copied into the
    /// check by hand, so editing the real scrim could not fail anything. Both
    /// ends come through here now — the foot spent a long time as exactly that
    /// literal, which left the darker half of the gradient ungated at 0.74
    /// against a bar of 0.75.
    ///
    /// It no longer keys off the wash's luminance, and that deletion is the
    /// point.
    /// `capped()` pins every colourful palette to the ceiling, so the term was
    /// a constant for six of eight covers on the bench — a sleeve with one neon
    /// dot on black and a sheet of blazing yellow are twelve times apart at the
    /// source and were arriving at an identical field. Where it did vary it
    /// varied the wrong way: `l * (1 - base - l)` is a downward parabola peaking
    /// at l = 0.42, so past that point a brighter record bought a DARKER panel.
    /// The ceiling is what bounds the worst case; the scrim was doing that job a
    /// second time and charging the record's colour for it. Constant now, so the
    /// field is proportional to the wash and a bright sleeve reads bright.
    /// The two states want opposite things, which is why `expanded` is here.
    /// Open, the panel is the place the record's colour lives. Retracted, the
    /// band belongs entirely to the menu bar and has to read as an extension of
    /// the cutout's black — lighting it up turns the shell into a coloured slab
    /// sitting on top of the menu bar, which is the one thing the hardware-first
    /// rule forbids. Lifting the open panel without this took the closed band
    /// from 0.0248 to 0.0942 relative luminance, measured against the wallpaper
    /// it sits on: a 3.8x lift on the state that asked for none.
    static func scrimAlpha(depth: Double = 0, expanded: Bool = true) -> Double {
        guard expanded else { return retractedScrim }
        return scrimHead + (scrimFoot - scrimHead) * min(1, max(0, depth))
    }
    /// 0.30/0.42, where these were 0.62/0.74 at the ceiling, because the old
    /// numbers were tuned against a ruler that read about three times short by
    /// scoring gamma-encoded values as light. Measured on the shipped panel,
    /// white type over this field was at 9.14:1 while the gate believed 4.65:1,
    /// and a real 4.5:1 permits the field at sRGB 118/255 where it was sitting
    /// at 53. Under the true-luminance ceiling the worst legal wash is the
    /// neutral sitting exactly on it, and these land white type over that at
    /// 7.80:1 at the head and 9.73:1 at the foot — still well over the AA
    /// line, on a panel about twice as bright.
    static let scrimHead = 0.30
    static let scrimFoot = 0.42
    /// What the head used to be at the ceiling, kept for the closed band alone,
    /// because that is the value the menu bar was already living with. No
    /// gradient: the band is a couple of dozen points tall and would only ever
    /// sample the top of one.
    static let retractedScrim = 0.62

    /// White type's contrast ratio over the composited field, in real WCAG
    /// terms: the black scrim composites per channel in gamma space — which is
    /// where SwiftUI actually blends, measured to 2/255 — and each channel is
    /// linearised BEFORE the weights are applied.
    ///
    /// The order is the whole function. An earlier version scored a gamma-
    /// encoded field directly against 1.05, which made the panel three times
    /// darker than anything asked for; the version after that linearised the
    /// already-weighted sum, and the sRGB curve is convex, so by Jensen's
    /// inequality lin(Σw·v) ≤ Σw·lin(v) with equality only on greys — the
    /// field was understated and the ratio inflated exactly on saturated
    /// covers, 12.67:1 reported over a magenta field that truly offers 5.91:1.
    /// A grey test point agrees with every ordering to the digit, which is why
    /// the gate never caught either mistake on its own.
    static func titleContrast(over peak: Peak, depth: Double = 0) -> Double {
        1.05 / (fieldLuminance(under: peak, depth: depth) + 0.05)
    }

    /// The light the scrimmed field actually emits behind the type.
    static func fieldLuminance(under peak: Peak, depth: Double = 0,
                               expanded: Bool = true) -> Double {
        let keep = 1 - scrimAlpha(depth: depth, expanded: expanded)
        return relativeLuminance(of: Peak(r: peak.r * keep,
                                          g: peak.g * keep,
                                          b: peak.b * keep))
    }

    /// Chrome-tier type — the band clocks, the idle card — over the same
    /// field. Translucent white composites in gamma space like everything else.
    static func chromeContrast(over peak: Peak, depth: Double = 0) -> Double {
        let keep = 1 - scrimAlpha(depth: depth)
        let a = chromeTypeAlpha
        let type = Peak(r: a + (1 - a) * peak.r * keep,
                        g: a + (1 - a) * peak.g * keep,
                        b: a + (1 - a) * peak.b * keep)
        return (relativeLuminance(of: type) + 0.05)
            / (fieldLuminance(under: peak, depth: depth) + 0.05)
    }

    /// The chrome text tier's opacity. Lives here for the same reason the scrim
    /// does: as a literal in NotchView, palettecheck could only ever gate a
    /// hand copy. 0.62 measured 3.63:1 over the worst legal wash — under AA
    /// for the 10.5pt clocks it paints — and 0.74 clears 4.5:1 everywhere
    /// while staying below the 0.76 the artist line wears, so the ranks still
    /// read.
    static let chromeTypeAlpha = 0.74

    /// The no-artwork wash, put through the same mill every extracted palette is.
    ///
    /// This was four `Color` literals with the wash's luminance written beside
    /// them by hand, and being a literal it skipped `capped()` — so it was the
    /// one palette in the app subject to no rule at all. It has now been wrong
    /// twice for that reason. First the declared figure said 0.30 while the
    /// palette's own brightest colour measured 0.476, and since the scrim was
    /// derived from that field, under-declaring it under-scrimmed: white type
    /// over the no-artwork wash sat at 3.42:1. That was fixed by correcting the
    /// number, which left the second fault in place — 0.476 was over the
    /// ceiling, so
    /// the panel shown when there is NO record was brighter than any real record
    /// is allowed to make it.
    ///
    /// Both faults were the same fault: a literal cannot be wrong about itself
    /// if it is not asked to describe itself. The seed colours stay hand-picked,
    /// because a neutral wash for "no cover" is a design choice and not something
    /// to derive. Everything downstream of them is computed — `capped()` brings
    /// them under the ceiling exactly as it does a real sleeve's, and `peak()`
    /// reports what that produced. Neither number can drift from the other again
    /// because neither is written down.
    static let fallback: ArtworkPalette = {
        let seed: [(r: Double, g: Double, b: Double)] = [
            (0.18, 0.55, 0.62),
            (0.10, 0.32, 0.44),
            (0.28, 0.24, 0.52),
            (0.08, 0.18, 0.28),
        ]
        let hsb = capped(seed.map { rgbToHSB($0.r, $0.g, $0.b) })
        return ArtworkPalette(colors: hsb.map(Self.color),
                              // Mean of the seeds, the same quantity `extract`
                              // reports: dark art needs a lift to stay legible.
                              luminance: 0.22,
                              washPeak: Self.peak(of: hsb))
    }()

    /// `nil` when the image can't be rasterised — callers keep their previous
    /// palette rather than flashing to the fallback.
    static func extract(from image: NSImage) -> ArtworkPalette? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return nil }

        // 24x24. It was a parameter with a default that every call site took —
        // five in palettecheck and one in MediaManager — so it was configurable
        // in name only.
        let w = 24, h = 24
        // The buffer is held by `withUnsafeMutableBytes`, not handed out by `&`.
        //
        // `CGContext(data: &pixels, ...)` passes a pointer that Swift only
        // guarantees for the duration of that one call, while CGContext keeps it
        // and writes through it on every `draw`. It happened to work because the
        // array is heap-allocated and nothing reallocated it, but the guarantee
        // is not there and the compiler is free to take it away.
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

        // 12 hue buckets, accumulating saturated pixels only. Greys carry no
        // identity and would wash every palette toward the same muddy centre.
        var buckets = [(r: Double, g: Double, b: Double, weight: Double)](
            repeating: (0, 0, 0, 0), count: 12)
        var lumaSum = 0.0
        var counted = 0.0
        // Mean colour, greys included: the only description of a monochrome
        // sleeve, which the bucket pass below discards entirely.
        var rSum = 0.0, gSum = 0.0, bSum = 0.0

        for i in stride(from: 0, to: pixels.count, by: 4) {
            let a = Double(pixels[i + 3]) / 255
            guard a > 0.35 else { continue }
            let r = Double(pixels[i]) / 255
            let g = Double(pixels[i + 1]) / 255
            let b = Double(pixels[i + 2]) / 255

            lumaSum += 0.2126 * r + 0.7152 * g + 0.0722 * b
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
            // Weight by saturation *and* brightness: a vivid mid-tone should beat
            // both a pastel and a near-black of the same hue.
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

        // A greyscale sleeve has no bucket above the saturation floor, so this
        // used to return nil — and callers keep their previous palette on nil, so
        // a black-and-white cover wore the *previous song's* colour. Confidently
        // wrong is worse than a default: the shell claims to wear the record.
        // Answer a monochrome record with a monochrome shell instead.
        guard !ranked.isEmpty else {
            guard counted > 0 else { return nil }
            let base = rgbToHSB(rSum / counted, gSum / counted, bSum / counted)
            let steps: [(s: Double, b: Double)] = [(0.12, 1.00), (0.08, 0.74),
                                                   (0.16, 1.12), (0.06, 0.55)]
            let hsb = capped(steps.map {
                (h: base.h, s: $0.s, b: min(1, max(0.12, base.b * $0.b)))
            })
            return ArtworkPalette(colors: hsb.map(Self.color),
                                  luminance: mean,
                                  washPeak: Self.peak(of: hsb))
        }

        let hsb = capped(spread(ranked))
        return ArtworkPalette(colors: hsb.map(Self.color),
                              luminance: mean,
                              washPeak: Self.peak(of: hsb))
    }

    /// Internal, not private, for the same reason `capped` is: palettecheck
    /// walks the reachable colour set through the real pipeline.
    typealias HSB = (h: Double, s: Double, b: Double)

    private static func color(_ e: HSB) -> Color {
        Color(hue: e.h, saturation: e.s, brightness: e.b)
    }

    /// Relative luminance as WCAG actually defines it: linearise, then weight.
    ///
    /// Takes a gamma-encoded grey level and returns the light it stands for.
    /// A previous session spent itself chasing a contrast defect that did not
    /// exist because WCAG's weights were being applied to gamma-encoded
    /// components: same numeral, two scales — 0.1833 encoded is sRGB 47/255,
    /// while 0.1833 of real luminance is sRGB 118/255.
    static func relativeLuminance(encoded v: Double) -> Double {
        v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
    }

    /// The full definition for a colour: linearise EACH channel, then weight.
    /// The two steps do not commute — see `titleContrast`.
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

    /// Pull every colour under the ceiling without touching hue.
    ///
    /// The cap is on TRUE luminance, and that is not a one-division scale:
    /// brightness moves the light through a power curve with an offset, and the
    /// saturation compensation below moves it again, so the scale is found by
    /// bisection with the boost folded in. Monotone in the scale — brightness
    /// falls with it and the boost only ever pulls the minor channels further
    /// down — so bisection converges from the safe side.
    ///
    /// Internal, not private: palettecheck walks the reachable colour set
    /// through this exact function. The ruler it scores that set with is
    /// derived from the WCAG spec independently, but the SET has to be the
    /// code's own, or the walk proves things about colours the app never
    /// paints.
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

    /// Saturation rises as brightness falls.
    ///
    /// Scaling brightness alone is what made pale covers wash out to mud: a
    /// light colour taken down in HSB keeps its saturation NUMBER while losing
    /// almost all of its perceived chroma, and the result reads as dirty rather
    /// than deep. Real dark colours are more saturated than their light
    /// counterparts, not equally so. Compensating in inverse proportion to the
    /// darkening keeps the record's colour recognisable at the luminance the
    /// type needs.
    private static func dimmed(_ e: HSB, scale: Double) -> HSB {
        (e.h, min(1, e.s * (1 + (1 - scale) * 1.15)), min(1, e.b * scale))
    }

    /// Guarantee four visibly different colours.
    ///
    /// A near-monochrome cover extracts four almost identical colours, and an
    /// animated gradient built from them has nothing to animate *between* — the
    /// field moves but you cannot see it. Where the source doesn't supply enough
    /// variation, derive it by rotating hue and pushing brightness apart, so the
    /// motion reads on any artwork.
    private static func spread(_ found: [(r: Double, g: Double, b: Double)]) -> [HSB] {
        var hsb = found.map { rgbToHSB($0.r, $0.g, $0.b) }

        // Anchor on the strongest colour, then fan the rest out around it.
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
            // Constant false at i == 0, where `existing` IS `base` and the
            // distance is zero — so the first slot always takes the synthesised
            // branch, which for offset 0 is `base` with the saturation and
            // brightness floors applied. That is the intent; it just is not a
            // choice being made.
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

        // Exactly four by construction: it starts as `ranked`, which is already
        // `.prefix(4)`, and the loop only ever appends when an index is missing.
        // The `prefix(4)` that used to be here could not trim anything.
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
