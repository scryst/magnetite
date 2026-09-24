import SwiftUI

/// The notch silhouette.
///
/// Two things make this read as hardware rather than a floating black box:
///
///  * **It is anchored at the top of the screen, not floating below it.** The
///    shape is drawn top-centre at its own size with straight sides and rounded
///    bottom corners, so it drops out of the display edge rather than hovering
///    in the menu bar.
///  * **It grows out of the notch, not over it.** Retracted it is exactly the
///    cutout, and it widens within the menu-bar band before it ever grows down.
///
/// The concave top fillet this comment used to describe went with `flaredPath`
/// in 53ef8d2: on screen it read as the panel splaying at the shoulders rather
/// than dropping cleanly out of the display edge.
///
/// All four animated values interpolate together so the frame and both radii
/// morph as one continuous animation.
///
/// (SwiftUI's `@Animatable` macro would generate that, but its macro plugin ships
/// with Xcode, not Command Line Tools — so the pairs are spelled out.)
struct NotchShape: Shape, Animatable {
    enum Style {
        /// Physical cutout: hugs the top edge of the display.
        case notch
        /// Free-floating pill, for displays with no notch.
        case pill
    }

    var topCornerRadius: CGFloat
    var bottomCornerRadius: CGFloat
    /// Drawn size. The window never resizes — we interpolate the shape inside a
    /// fixed-size panel, which is what keeps the morph perfectly smooth.
    var width: CGFloat
    var height: CGFloat

    var style: Style = .notch

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>,
                                       AnimatablePair<CGFloat, CGFloat>> {
        get { .init(.init(width, height), .init(topCornerRadius, bottomCornerRadius)) }
        set {
            width = newValue.first.first
            height = newValue.first.second
            topCornerRadius = newValue.second.first
            bottomCornerRadius = newValue.second.second
        }
    }

    init(width: CGFloat,
         height: CGFloat,
         topCornerRadius: CGFloat = 6,
         bottomCornerRadius: CGFloat = 13,
         style: Style = .notch,
    ) {
        self.width = width
        self.height = height
        self.topCornerRadius = topCornerRadius
        self.bottomCornerRadius = bottomCornerRadius
        self.style = style
    }

    /// The pill's effective corner radius. The floor is what keeps a
    /// menu-bar-height capsule reading as a capsule when the hardware cutout
    /// radius (tuned for a notch) comes in lower; the half-height clamp keeps
    /// the floor legal on a shell too short to carry it. A named rule because
    /// three consumers draw this corner — the silhouette, the trace, and the
    /// trim mapping that keeps the playhead on it — and while the floor lived
    /// only in the silhouette, the trace rounded at 9 − inset against a shell
    /// rounding at 10 and its ink left the shape at both bottom corners.
    /// Idempotent, so the silhouette re-applying it to a value the controller
    /// already passed through it changes nothing.
    static func pillCornerRadius(height: CGFloat, bottomCornerRadius: CGFloat) -> CGFloat {
        min(height / 2, max(bottomCornerRadius, 10))
    }

    /// The shape is always drawn top-centre within `rect`, at its own size.
    func path(in rect: CGRect) -> Path {
        let w = max(1, width), h = max(1, height)
        let frame = CGRect(x: rect.midX - w / 2, y: rect.minY, width: w, height: h)

        switch style {
        case .pill:
            // The same quad construction as the notch branch, not
            // `Path(roundedRect:)`: that initializer's corners are a different
            // curve family from the quadratic quarter-turns `NotchBottomEdge`
            // draws, so the trace could not sit on this silhouette no matter
            // what radius both were handed.
            let r = Self.pillCornerRadius(height: frame.height,
                                          bottomCornerRadius: bottomCornerRadius)
            return simplePath(in: frame, topRadius: r, bottomRadius: r)
        case .notch:
            // One continuous shell that wraps *around* the cutout. The camera
            // housing disappears into it because the menu-bar band is kept pure
            // black — see `NotchRootView.ambientGlow`, which is masked off above
            // the notch line. Growing only downward instead would waste the space
            // either side of the cutout, which is the whole point of the format.
            return simplePath(in: frame, topRadius: topCornerRadius,
                              bottomRadius: bottomCornerRadius)
        }
    }

    /// Straight sides, rounded bottom corners.
    ///
    /// The sides run **vertically** from the top edge. An earlier version put a
    /// concave fillet at the top so the shape flared outward into the bezel; on
    /// screen that reads as the panel splaying at the shoulders rather than
    /// dropping cleanly out of the display edge.
    private func simplePath(in rect: CGRect, topRadius: CGFloat, bottomRadius: CGFloat) -> Path {
        let br = max(0, min(bottomRadius, min(rect.height / 2, rect.width / 2)))
        // No gate. The retracted shell rounds its top so it reads as a capsule
        // in the menu bar and the expanded one squares it so it reads as dropping
        // out of the display edge — but those are two forms of ONE object only if
        // the shoulders unroll. A Bool snapped them square on frame one, which
        // made the shell look like two shapes crossfading behind a size change,
        // right where the pointer had just entered. As a radius it interpolates
        // inside the existing animatableData.
        let tr = max(0, min(topRadius, min(rect.height / 2, rect.width / 2)))

        var p = Path()
        let minX = rect.minX, maxX = rect.maxX, minY = rect.minY, maxY = rect.maxY

        p.move(to: CGPoint(x: minX + tr, y: minY))
        if tr > 0 {
            p.addQuadCurve(to: CGPoint(x: minX, y: minY + tr),
                           control: CGPoint(x: minX, y: minY))
        }
        p.addLine(to: CGPoint(x: minX, y: maxY - br))
        p.addQuadCurve(to: CGPoint(x: minX + br, y: maxY),
                       control: CGPoint(x: minX, y: maxY))
        p.addLine(to: CGPoint(x: maxX - br, y: maxY))
        p.addQuadCurve(to: CGPoint(x: maxX, y: maxY - br),
                       control: CGPoint(x: maxX, y: maxY))
        p.addLine(to: CGPoint(x: maxX, y: minY + tr))
        if tr > 0 {
            p.addQuadCurve(to: CGPoint(x: maxX - tr, y: minY),
                           control: CGPoint(x: maxX, y: minY))
        }
        p.closeSubpath()
        return p
    }

}

/// Motion vocabulary.
///
/// One place for every curve in the app, so the whole surface moves as a system
/// rather than a pile of ad-hoc `.easeInOut`s. Springs also give us interruptible
/// motion for free — reverse a gesture mid-flight and it settles correctly
/// instead of snapping.
enum Motion {
    /// Mirrors `NSWorkspace.accessibilityDisplayShouldReduceMotion`, kept current
    /// by `NotchCoordinator`.
    ///
    /// Reduce Motion takes the impulse and travel out of the vocabulary — every
    /// state change still happens and still reads, it just stops springing and
    /// bouncing. It must never remove a state change: an inert or ambiguous
    /// panel is worse than a lively one.
    static var reduceMotion = false

    /// The notch opening. Enough bounce to feel physical, not cartoonish.
    static var expand: Animation {
        reduceMotion ? .easeOut(duration: 0.20)
                     : .spring(response: 0.42, dampingFraction: 0.74)
    }
    /// Closing is slightly faster and fully damped — no overshoot on the way out.
    static var collapse: Animation {
        reduceMotion ? .easeOut(duration: 0.16)
                     : .spring(response: 0.34, dampingFraction: 0.88)
    }
    /// Content fading in behind the shape.
    static var content: Animation {
        reduceMotion ? .easeOut(duration: 0.16) : .smooth(duration: 0.28)
    }
    /// Live activity / HUD swaps.
    static var swap: Animation {
        reduceMotion ? .easeOut(duration: 0.16)
                     : .spring(response: 0.34, dampingFraction: 0.82)
    }
    /// Progress and level bars: no bounce, they read as measurement.
    static var meter: Animation {
        reduceMotion ? .easeOut(duration: 0.14) : .smooth(duration: 0.22)
    }
    /// Entrance/exit travel scalar.
    ///
    /// Reduce Motion keeps the direction and the timing of every arrival and
    /// takes most of the distance out — the same rule the ink already uses.
    static var travel: CGFloat { reduceMotion ? 0.4 : 1 }

    /// Revealing and grabbing the scrubber.
    static var seek: Animation {
        reduceMotion ? .easeOut(duration: 0.14)
                     : .spring(response: 0.26, dampingFraction: 0.72)
    }
    /// Track change — the one place a little extra bounce is earned.
    static var track: Animation {
        reduceMotion ? .easeOut(duration: 0.20)
                     : .bouncy(duration: 0.52, extraBounce: 0.12)
    }

    /// The content sheet following the fingers mid-swipe.
    ///
    /// Jitter absorption only, deliberately not a spring: the offset re-targets
    /// on every trackpad delta, and a curve with its own opinion about where
    /// the sheet should be reads as the sheet resisting the hand. Reduce
    /// Motion needs no branch — the travel scalar already shrinks the shift,
    /// and 50ms of linear smoothing is not motion, it is the absence of steps.
    static var leanFollow: Animation { .linear(duration: 0.05) }
    /// The sheet easing home after the fingers commit or abort. Fully damped:
    /// the commit's answer is the ink's surge, and a sheet that bounced back
    /// would be a second, smaller answer arriving late.
    static var leanRelease: Animation {
        reduceMotion ? .easeOut(duration: 0.14) : .easeOut(duration: 0.30)
    }
}

/// Just the bottom edge of `NotchShape`, as an open path.
///
/// Trimming this and stroking it draws playback progress along the panel's own
/// silhouette — the panel becomes its own scrubber, so no vertical space is spent
/// on a separate track.
struct NotchBottomEdge: Shape {
    var width: CGFloat
    var height: CGFloat
    var bottomCornerRadius: CGFloat
    /// Half the stroke's width, so the line's OUTER edge lands on the silhouette
    /// instead of straddling it.
    ///
    /// Centred on the path, half of every stroke fell outside the shell: clipped
    /// where something clips, and sitting past the menu-bar band where nothing
    /// does. It also has to animate, because the width swells on hover and again
    /// on grab — a static inset would make the line jump as it thickened.
    var inset: CGFloat = 0

    /// The radius has to interpolate along with the frame. Animating only
    /// width/height made the corner radius jump to its target on frame one of
    /// every expand, so the trace peeled away from the silhouette it is supposed
    /// to be drawn on and snapped back at the end of the morph.
    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>,
                                       AnimatablePair<CGFloat, CGFloat>> {
        get { .init(.init(width, height), .init(bottomCornerRadius, inset)) }
        set {
            width = newValue.first.first
            height = newValue.first.second
            bottomCornerRadius = newValue.second.first
            inset = newValue.second.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let w = max(1, width - inset * 2), h = max(1, height - inset)
        let frame = CGRect(x: rect.midX - w / 2, y: rect.minY, width: w, height: h)
        // Must mirror NotchShape.simplePath exactly, or the trace sits outside the
        // silhouette.
        // Must match NotchShape.simplePath's clamp exactly (height / 2, not
        // height), or the trace rounds differently from the shell it traces.
        //
        // The inset shrinks the corner along with the frame. Clamping the SHELL's
        // radius against an inset frame TRANSLATES the corner by (inset, -inset)
        // instead of offsetting it: exact at both tangent points, `inset * sqrt(2)`
        // along the normal at 45 degrees, so the stroke's outer boundary drifted
        // `inset * (sqrt(2) - 1)` INSIDE the silhouette — 0.52pt at rest and 0.83pt
        // while scrubbing, on both corners, in the one gesture that puts the
        // pointer there. The straight run was right and the arcs were not, which is
        // why the bottom-edge assert never saw it.
        let br = max(0, min(bottomCornerRadius - inset,
                            min(frame.height / 2, frame.width / 2)))

        var p = Path()
        p.move(to: CGPoint(x: frame.minX, y: frame.maxY - br))
        p.addQuadCurve(to: CGPoint(x: frame.minX + br, y: frame.maxY),
                       control: CGPoint(x: frame.minX, y: frame.maxY))
        p.addLine(to: CGPoint(x: frame.maxX - br, y: frame.maxY))
        p.addQuadCurve(to: CGPoint(x: frame.maxX, y: frame.maxY - br),
                       control: CGPoint(x: frame.maxX, y: frame.maxY))
        return p
    }
}
