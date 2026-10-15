import AppKit
import SwiftUI
import Foundation

/// Headless checks for the album-art palette.
///
/// The failures covered here only appear with particular kinds of artwork, by
/// which point the panel is already illegible or wearing the wrong record's
/// colour.
@main
enum PaletteCheck {
    static func main() {
        washCannotOutshineTheCeiling()
        monochromeCoverGetsItsOwnPalette()
        typeStaysLegibleOnEveryCover()
        chromeTypeStaysLegibleToo()
        theClosedBandStaysInTheMenuBar()
        theContrastRulerIsLinearised()
        theRulerWeighsAfterItLinearises()
        theFallbackDescribesItself()
        unrasterisableArtStillReturnsNil()
        print("palettecheck: all checks passed")
    }

    // MARK: The check's own ruler

    // Written from the WCAG definition rather than from ArtworkPalette: linearise
    // each channel with the sRGB EOTF, then weight. Agreement with the app's
    // arithmetic is asserted below; a shared implementation would validate
    // nothing.
    private static func lum(_ v: Double) -> Double {
        v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
    }
    private static func lum(_ p: ArtworkPalette.Peak) -> Double {
        0.2126 * lum(p.r) + 0.7152 * lum(p.g) + 0.0722 * lum(p.b)
    }
    /// The black scrim composites per channel in gamma space (as SwiftUI does),
    /// so the field is the colour scaled before it is linearised.
    private static func field(_ p: ArtworkPalette.Peak, scrim: Double)
        -> ArtworkPalette.Peak {
        .init(r: p.r * (1 - scrim), g: p.g * (1 - scrim), b: p.b * (1 - scrim))
    }
    private static func specTitle(_ p: ArtworkPalette.Peak, scrim: Double) -> Double {
        1.05 / (lum(field(p, scrim: scrim)) + 0.05)
    }
    private static func specChrome(_ p: ArtworkPalette.Peak, scrim: Double,
                                   alpha a: Double) -> Double {
        let f = field(p, scrim: scrim)
        let type = ArtworkPalette.Peak(r: a + (1 - a) * f.r,
                                       g: a + (1 - a) * f.g,
                                       b: a + (1 - a) * f.b)
        return (lum(type) + 0.05) / (lum(f) + 0.05)
    }

    /// Every colour a palette may legally carry: an HSB lattice pushed through
    /// the real `capped()`. The set must be the code's own; a hand-built set
    /// could prove things about colours the app never paints.
    private static let reachable: [ArtworkPalette.Peak] = {
        var out: [ArtworkPalette.Peak] = []
        for h in stride(from: 0.0, to: 1.0, by: 1.0 / 48) {
            for s in [0.0, 0.35, 0.6, 0.8, 1.0] {
                for b in stride(from: 0.1, through: 1.0, by: 0.1) {
                    let e = ArtworkPalette.capped([(h: h, s: s, b: b)])[0]
                    let c = NSColor(hue: e.h, saturation: e.s, brightness: e.b,
                                    alpha: 1).usingColorSpace(.sRGB)!
                    out.append(.init(r: Double(c.redComponent),
                                     g: Double(c.greenComponent),
                                     b: Double(c.blueComponent)))
                }
            }
        }
        return out
    }()

    // MARK: Checks

    /// No wash colour may emit more light than the ceiling, and `washPeak` must be
    /// the brightest colour actually painted. The hard case is a dark sleeve with
    /// one neon element: the bucket pass drops the greys, so the accent wins and
    /// `spread`'s 1.18 brightness offset could exceed full brightness.
    private static func washCannotOutshineTheCeiling() {
        for art in [neonOnBlack, pureWhite, vividRed] {
            guard let p = ArtworkPalette.extract(from: art) else {
                fail("a rasterisable cover produced no palette")
            }
            require(lum(p.washPeak) <= ArtworkPalette.washLuminanceCeiling + 1e-4,
                    "wash peak emits \(lum(p.washPeak)) against a ceiling of "
                    + "\(ArtworkPalette.washLuminanceCeiling)")
            // A peak picked by the wrong rule would let a brighter colour ship
            // ungated beside it.
            let brightest = p.colors.map { c -> Double in
                let n = NSColor(c).usingColorSpace(.sRGB) ?? .black
                return lum(.init(r: Double(n.redComponent),
                                 g: Double(n.greenComponent),
                                 b: Double(n.blueComponent)))
            }.max() ?? 0
            require(abs(brightest - lum(p.washPeak)) < 0.005,
                    "washPeak emits \(lum(p.washPeak)) but the brightest painted "
                    + "colour emits \(brightest) — the peak is not the peak")
        }
    }

    /// Greyscale art must produce its own palette. A nil result makes callers
    /// keep the previous palette, so a black-and-white cover would wear the last
    /// song's colour.
    private static func monochromeCoverGetsItsOwnPalette() {
        guard let grey = ArtworkPalette.extract(from: greyscale) else {
            fail("greyscale cover returned no palette (it would inherit the last track's)")
        }
        require(grey.colors.count == 4, "expected four wash colours")
        let red = ArtworkPalette.extract(from: vividRed)!
        require(distance(grey.colors[0], red.colors[0]) > 0.12,
                "greyscale palette came out the same as a red cover's")
    }

    /// White type holds contrast over the composited wash, and the wash survives
    /// the scrim that guarantees it.
    ///
    /// The bar is 7:1 rather than AA's 4.5:1. With the scrim deleted entirely the
    /// neutral at the ceiling still measures 4.71:1, so an AA bar would certify a
    /// wash bright enough to swallow the artwork. 7:1 is the product line from
    /// PRODUCT.md.
    ///
    /// Asserted over the whole reachable set with the check's own ruler, at the
    /// head: a deeper scrim only darkens the field, so the top of the gradient
    /// is the worst case for the type.
    private static func typeStaysLegibleOnEveryCover() {
        for (name, art) in [("neon-on-black", neonOnBlack), ("white", pureWhite),
                            ("vivid red", vividRed), ("greyscale", greyscale)] {
            guard let p = ArtworkPalette.extract(from: art) else { continue }
            let ratio = ArtworkPalette.titleContrast(over: p.washPeak)
            require(ratio >= 7.0,
                    "white title over \(name) is only \(String(format: "%.2f", ratio)):1")
        }
        let head = ArtworkPalette.scrimAlpha()
        for p in reachable {
            require(specTitle(p, scrim: head) >= 7.0,
                    "white title over legal wash (\(String(format: "%.3f", p.r)), "
                    + "\(String(format: "%.3f", p.g)), \(String(format: "%.3f", p.b))) "
                    + "is only \(String(format: "%.2f", specTitle(p, scrim: head))):1")
            // The app's ruler and the spec's must agree everywhere; if they
            // drift, one of them is not measuring light.
            require(abs(ArtworkPalette.titleContrast(over: p) - specTitle(p, scrim: head)) < 0.01,
                    "titleContrast disagrees with the WCAG definition at "
                    + "(\(String(format: "%.3f", p.r)), \(String(format: "%.3f", p.g)), "
                    + "\(String(format: "%.3f", p.b)))")
        }

        // The opposing bound: the scrim that protects the type also eats the
        // record's colour, and is deepest at the foot.
        let foot = ArtworkPalette.scrimAlpha(depth: 1)
        require(foot <= 0.50,
                "the scrim reaches \(String(format: "%.2f", foot)) at the panel's foot — that is "
                + "a black panel, and the album colour it exists to protect is gone")
        // The gradient must darken downward; reversed, the panel lights from the
        // bottom and reads as a shadow cast upward onto the notch.
        require(foot >= head,
                "the scrim's foot (\(String(format: "%.2f", foot))) is lighter than its head "
                + "(\(String(format: "%.2f", head))) — the gradient runs the wrong way")
    }

    /// The 10.5 pt band clocks and the idle card wear `chromeTypeAlpha` white,
    /// and small translucent type is the tier that binds. AA's 4.5:1 must hold
    /// over every legal wash. The constant lives in ArtworkPalette so this check
    /// gates the value the views actually use.
    private static func chromeTypeStaysLegibleToo() {
        let head = ArtworkPalette.scrimAlpha()
        let alpha = ArtworkPalette.chromeTypeAlpha
        for (name, art) in [("neon-on-black", neonOnBlack), ("white", pureWhite),
                            ("vivid red", vividRed), ("greyscale", greyscale)] {
            guard let p = ArtworkPalette.extract(from: art) else { continue }
            let ratio = ArtworkPalette.chromeContrast(over: p.washPeak)
            require(ratio >= 4.5,
                    "chrome type over \(name) is only \(String(format: "%.2f", ratio)):1")
        }
        for p in reachable {
            require(specChrome(p, scrim: head, alpha: alpha) >= 4.5,
                    "chrome type over legal wash (\(String(format: "%.3f", p.r)), "
                    + "\(String(format: "%.3f", p.g)), \(String(format: "%.3f", p.b))) "
                    + "is only \(String(format: "%.2f", specChrome(p, scrim: head, alpha: alpha))):1")
            require(abs(ArtworkPalette.chromeContrast(over: p)
                        - specChrome(p, scrim: head, alpha: alpha)) < 0.01,
                    "chromeContrast disagrees with the WCAG definition")
        }
    }

    /// Retracted, the shell must read as a strip of menu bar, not a coloured
    /// slab. Open and closed once shared one scrim, so lightening the open panel
    /// also lit the band (0.0248 to 0.0942 relative luminance). PRODUCT.md gives
    /// the retracted state entirely to the hardware, so the rule belongs in the
    /// gate.
    private static func theClosedBandStaysInTheMenuBar() {
        let open = ArtworkPalette.scrimAlpha(depth: 1)
        let closed = ArtworkPalette.scrimAlpha(expanded: false)
        require(closed >= open,
                "the closed band's scrim (\(String(format: "%.2f", closed))) is lighter than the "
                + "open panel's deepest point (\(String(format: "%.2f", open))) — retracting the "
                + "notch would brighten it")
        // Plus an absolute bound over every legal wash, since "darker than the
        // open panel" is only relative and both could drift up together.
        for p in reachable {
            let lit = lum(field(p, scrim: closed))
            require(lit <= 0.035,
                    "the closed band sits at \(String(format: "%.4f", lit)) relative luminance "
                    + "under a legal wash — that is a lit slab on the menu bar, not the notch")
        }
    }

    /// Pins the sRGB transfer curve so encoded and linear values cannot merge
    /// again. WCAG's weights apply to linearised components; applied to
    /// gamma-encoded ones the result is not relative luminance and must not be
    /// scored against 1.05.
    private static func theContrastRulerIsLinearised() {
        // Mid grey: sRGB 0.5 encodes about 21.4% of the light, not 50%.
        let mid = ArtworkPalette.relativeLuminance(encoded: 0.5)
        require(abs(mid - 0.2140) < 0.001,
                "sRGB 0.5 linearises to \(String(format: "%.4f", mid)), expected 0.2140 — "
                + "the transfer curve is wrong")
        // The endpoints must survive exactly, or every ratio drifts.
        require(ArtworkPalette.relativeLuminance(encoded: 0) == 0,
                "black did not linearise to 0")
        require(abs(ArtworkPalette.relativeLuminance(encoded: 1) - 1) < 1e-9,
                "white did not linearise to 1")
        // Scoring encoded values directly understates the ratio badly: on the
        // neutral at the old encoded ceiling the naive form gives about 2.8:1
        // where the truth is 7.8:1.
        let neutral = ArtworkPalette.Peak(r: 0.46, g: 0.46, b: 0.46)
        let naive = 1.05 / (0.46 * (1 - ArtworkPalette.scrimAlpha()) + 0.05)
        let real = ArtworkPalette.titleContrast(over: neutral)
        require(real > naive * 1.5,
                "linearising changed the neutral's ratio from \(String(format: "%.2f", naive)) "
                + "to \(String(format: "%.2f", real)) — that is not what the gamma curve owes, "
                + "so titleContrast is probably scoring encoded values again")
    }

    /// Pins the order of linearise and weight, where a grey cannot tell the
    /// orderings apart: the weights sum to 1, so on r=g=b they agree. The sRGB
    /// curve is convex, so linearising the weighted sum understates every
    /// saturated field; pure magenta under the head scrim reports 12.67:1 for a
    /// field that truly offers 5.91:1.
    ///
    /// The constant is the WCAG value for the 0.30 head scrim, computed outside
    /// this repo so nothing in ArtworkPalette can drift it. If the head scrim is
    /// retuned, recompute it the same way; a failure here after a scrim edit is
    /// this check working.
    private static func theRulerWeighsAfterItLinearises() {
        let magenta = ArtworkPalette.Peak(r: 1, g: 0, b: 1)
        let ratio = ArtworkPalette.titleContrast(over: magenta)
        require(abs(ratio - 5.9126) < 0.02,
                "white over a magenta field measures \(String(format: "%.4f", ratio)):1, "
                + "expected 5.9126:1 — the ruler is weighing before it linearises "
                + "(the inflated ordering reports 12.67:1)")
    }

    /// The no-artwork palette obeys the same rules as an extracted one: its
    /// declared peak is its real brightest colour, and it sits under the ceiling.
    /// Hand-picked seeds do not pass through `capped()` on their own, so nothing
    /// else keeps the no-artwork panel from being the brightest field in the app.
    private static func theFallbackDescribesItself() {
        let p = ArtworkPalette.fallback
        let brightest = p.colors.map { c -> Double in
            let n = NSColor(c).usingColorSpace(.sRGB) ?? .black
            return lum(.init(r: Double(n.redComponent),
                             g: Double(n.greenComponent),
                             b: Double(n.blueComponent)))
        }.max() ?? 0
        require(abs(brightest - lum(p.washPeak)) < 0.005,
                "the fallback declares a peak emitting \(lum(p.washPeak)) but its "
                + "brightest colour emits \(String(format: "%.3f", brightest))")
        require(lum(p.washPeak) <= ArtworkPalette.washLuminanceCeiling + 1e-4,
                "the fallback's wash emits \(String(format: "%.3f", lum(p.washPeak))) against "
                + "a ceiling of \(ArtworkPalette.washLuminanceCeiling) — the one palette that "
                + "never goes through capped() is brighter than any cover is allowed to be")
        require(ArtworkPalette.titleContrast(over: p.washPeak) >= 7.0,
                "white type over the fallback wash is only "
                + "\(String(format: "%.2f", ArtworkPalette.titleContrast(over: p.washPeak))):1")
    }

    private static func unrasterisableArtStillReturnsNil() {
        require(ArtworkPalette.extract(from: NSImage(size: .zero)) == nil,
                "an empty image should still return nil so callers keep their palette")
    }

    // MARK: Fixtures

    private static var neonOnBlack: NSImage {
        make { x, y in (x < 4 && y < 4) ? (1.0, 0.95, 0.1) : (0.05, 0.05, 0.07) }
    }
    private static var pureWhite: NSImage { make { _, _ in (0.98, 0.98, 0.96) } }
    private static var vividRed: NSImage { make { _, _ in (0.75, 0.10, 0.12) } }
    private static var greyscale: NSImage {
        make { x, y in let v = Double((x + y) % 24) / 24 * 0.7 + 0.1; return (v, v, v) }
    }

    private static func make(_ body: (Int, Int) -> (Double, Double, Double)) -> NSImage {
        let n = 24
        var px = [UInt8](repeating: 0, count: n * n * 4)
        for y in 0..<n {
            for x in 0..<n {
                let (r, g, b) = body(x, y)
                let i = (y * n + x) * 4
                px[i] = UInt8(r * 255); px[i + 1] = UInt8(g * 255)
                px[i + 2] = UInt8(b * 255); px[i + 3] = 255
            }
        }
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(data: &px, width: n, height: n, bitsPerComponent: 8,
                            bytesPerRow: n * 4, space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return NSImage(cgImage: ctx.makeImage()!, size: NSSize(width: n, height: n))
    }

    private static func distance(_ a: Color, _ b: Color) -> Double {
        let x = NSColor(a).usingColorSpace(.sRGB)!, y = NSColor(b).usingColorSpace(.sRGB)!
        return abs(Double(x.redComponent - y.redComponent))
            + abs(Double(x.greenComponent - y.greenComponent))
            + abs(Double(x.blueComponent - y.blueComponent))
    }

    private static func require(_ ok: @autoclosure () -> Bool, _ message: String) {
        if !ok() { fail(message) }
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write("palettecheck: \(message)\n".data(using: .utf8)!)
        exit(1)
    }
}
