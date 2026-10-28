import SwiftUI

/// The notch silhouette.
///
/// Anchored at the top of the screen with straight sides and rounded bottom
/// corners, so it drops out of the display edge instead of hovering in the menu
/// bar. Collapsed it is exactly the cutout; it widens within the menu-bar band
/// before it grows downward.
///
/// Width, height and both radii interpolate together, so the morph is one
/// animation. `@Animatable` would generate this, but its macro plugin ships with
/// Xcode rather than the Command Line Tools, so the pairs are spelled out.
struct NotchShape: Shape, Animatable {
    enum Style {
        /// Physical cutout: hugs the top edge of the display.
        case notch
        /// Free-floating pill, for displays with no notch.
        case pill
    }

    var topCornerRadius: CGFloat
    var bottomCornerRadius: CGFloat
    /// Drawn size. The window never resizes; the shape interpolates inside a fixed-size
    /// panel.
    var width: CGFloat
    var height: CGFloat

    var style: Style = .notch
    /// How far the middle of the bottom edge hangs below the corners, in points. Set
    /// per frame by the pour, never animated by SwiftUI; negative bows it up.
    var sag: CGFloat = 0

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

    /// The pill's effective corner radius. The floor keeps a menu-bar-height capsule
    /// reading as a capsule when the notch-tuned radius is lower; the half-height clamp
    /// keeps the floor legal on a short shell. Shared because the silhouette, the trace
    /// and the playhead's trim mapping must all draw the same corner. Idempotent, so
    /// re-applying it to a value the controller already passed through changes nothing.
    static func pillCornerRadius(height: CGFloat, bottomCornerRadius: CGFloat) -> CGFloat {
        min(height / 2, max(bottomCornerRadius, 10))
    }

    /// The shape is always drawn top-centre within `rect`, at its own size.
    func path(in rect: CGRect) -> Path {
        let w = max(1, width), h = max(1, height)
        let frame = CGRect(x: rect.midX - w / 2, y: rect.minY, width: w, height: h)

        switch style {
        case .pill:
            // The same quad construction as the notch branch, not `Path(roundedRect:)`,
            // whose corners are a different curve family from the quadratic quarter-turns
            // `NotchBottomEdge` draws; the trace could not sit on that silhouette.
            let r = Self.pillCornerRadius(height: frame.height,
                                          bottomCornerRadius: bottomCornerRadius)
            return simplePath(in: frame, topRadius: r, bottomRadius: r)
        case .notch:
            // One shell that wraps around the cutout; the camera housing disappears into it
            // because the menu-bar band stays pure black. Growing only downward would waste
            // the space either side of the cutout.
            return simplePath(in: frame, topRadius: topCornerRadius,
                              bottomRadius: bottomCornerRadius)
        }
    }

    /// Straight sides from the top edge and rounded bottom corners. A concave top
    /// fillet would read as the panel splaying at the shoulders.
    private func simplePath(in rect: CGRect, topRadius: CGFloat, bottomRadius: CGFloat) -> Path {
        let br = max(0, min(bottomRadius, min(rect.height / 2, rect.width / 2)))
        // The top radius is a value, not a Bool: the collapsed shell rounds its top and
        // the expanded one squares it, and a snap on the first frame would look like two
        // shapes crossfading. As a radius it interpolates in `animatableData`.
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
        if abs(sag) > 0.05 {
            // Two halves with level tangents at the corners and the middle, so a moving
            // front has no kink anywhere: a liquid's leading edge, not a bent bar.
            let run = (maxX - minX - 2 * br) / 2, mid = rect.midX
            p.addCurve(to: CGPoint(x: mid, y: maxY + sag),
                       control1: CGPoint(x: minX + br + run * 0.55, y: maxY),
                       control2: CGPoint(x: mid - run * 0.45, y: maxY + sag))
            p.addCurve(to: CGPoint(x: maxX - br, y: maxY),
                       control1: CGPoint(x: mid + run * 0.45, y: maxY + sag),
                       control2: CGPoint(x: maxX - br - run * 0.55, y: maxY))
        } else {
            p.addLine(to: CGPoint(x: maxX - br, y: maxY))
        }
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

/// Motion vocabulary: every curve in the app, so the surface moves as a system.
/// Springs are interruptible, so reversing a gesture mid-flight settles instead of
/// snapping.
enum Motion {
    /// Mirrors `NSWorkspace.accessibilityDisplayShouldReduceMotion`, kept current by
    /// `NotchCoordinator`.
    ///
    /// Reduce Motion removes springing and travel but never a state change.
    static var reduceMotion = false

    /// The notch opening: enough bounce to feel physical.
    static var expand: Animation {
        reduceMotion ? .easeOut(duration: 0.20)
                     : .spring(response: 0.42, dampingFraction: 0.74)
    }
    /// Closing is faster and fully damped, with no overshoot.
    static var collapse: Animation {
        reduceMotion ? .easeOut(duration: 0.16)
                     : .spring(response: 0.34, dampingFraction: 0.88)
    }
    /// Content fading in behind the shape.
    static var content: Animation {
        reduceMotion ? .easeOut(duration: 0.16) : .smooth(duration: 0.28)
    }
    /// Live activity and HUD swaps.
    static var swap: Animation {
        reduceMotion ? .easeOut(duration: 0.16)
                     : .spring(response: 0.34, dampingFraction: 0.82)
    }
    /// The mini player's clock leaves fast, before the panel's content
    /// (`Pour.contentLag`) is visible, and returns only after that content's 0.175 s exit, so a readout is
    /// never on screen twice.
    static var miniClockOut: Animation { .easeOut(duration: 0.07) }
    static var miniClockIn: Animation {
        .easeOut(duration: reduceMotion ? 0.12 : 0.18).delay(0.16)
    }
    /// Progress and level bars: no bounce, they read as measurement.
    static var meter: Animation {
        reduceMotion ? .easeOut(duration: 0.14) : .smooth(duration: 0.22)
    }
    /// Entrance and exit travel scalar. Reduce Motion keeps direction and timing and
    /// takes most of the distance out.
    static var travel: CGFloat { reduceMotion ? 0.4 : 1 }

    /// Revealing and grabbing the scrubber.
    static var seek: Animation {
        reduceMotion ? .easeOut(duration: 0.14)
                     : .spring(response: 0.26, dampingFraction: 0.72)
    }
    /// Track change, the one place extra bounce is earned.
    static var track: Animation {
        reduceMotion ? .easeOut(duration: 0.20)
                     : .bouncy(duration: 0.52, extraBounce: 0.12)
    }

    /// The content sheet following the fingers mid-swipe.
    ///
    /// Jitter absorption rather than a spring: the offset re-targets on every
    /// trackpad delta, and a curve with its own target reads as resistance. No Reduce
    /// Motion branch is needed, since `travel` already shrinks the shift.
    static var leanFollow: Animation { .linear(duration: 0.05) }
    /// The sheet easing home after a commit or abort. Fully damped, so it does not add
    /// a second, smaller answer to the commit's surge.
    static var leanRelease: Animation {
        reduceMotion ? .easeOut(duration: 0.14) : .easeOut(duration: 0.30)
    }
}

/// The open, staged as a pour. The shell's bottom edge leads in the middle like the
/// front of a poured liquid, then wobbles flat; the colour fills the body behind it and
/// the content arrives last. Closing drains the colour up while the edge trails. One
/// timeline rather than a spring per value, so the order is a single fact
/// `chromecheck` can sample.
struct Pour: Equatable {
    /// How far the middle of the bottom edge hangs below its corners, in points.
    var sag: CGFloat = 0
    /// How much of the body the colour has filled, from the top.
    var fill: CGFloat = 0

    static func rest(open: Bool) -> Pour { Pour(fill: open ? 1 : 0) }

    /// When the content starts to arrive: once the colour is most of the way down.
    static var contentLag: Double { Motion.reduceMotion ? 0.07 : 0.14 }

    /// Reduce Motion keeps the order and loses the travel: a flat edge, a short fill.
    static func timeline(opening: Bool) -> KeyframeTimeline<Pour> {
        if Motion.reduceMotion {
            return KeyframeTimeline(initialValue: rest(open: !opening)) {
                KeyframeTrack(\.fill) { LinearKeyframe(opening ? 1 : 0, duration: 0.16) }
            }
        }
        if !opening {
            return KeyframeTimeline(initialValue: rest(open: true)) {
                KeyframeTrack(\.fill) { CubicKeyframe(0, duration: 0.16, startVelocity: 0) }
                // Drawn up from the corners, the middle trails, then lets go.
                KeyframeTrack(\.sag) {
                    CubicKeyframe(9, duration: 0.1)
                    SpringKeyframe(0, duration: 0.22, spring: Spring(response: 0.2, dampingRatio: 0.8))
                }
            }
        }
        return KeyframeTimeline(initialValue: rest(open: false)) {
            // Leads while the shell falls, then is caught: one bounce up past flat and
            // a smaller one back, as a surface settles.
            KeyframeTrack(\.sag) {
                CubicKeyframe(16, duration: 0.13, startVelocity: 0)
                SpringKeyframe(0, duration: 0.5, spring: Spring(response: 0.26, dampingRatio: 0.42))
            }
            KeyframeTrack(\.fill) {
                LinearKeyframe(0, duration: 0.03)
                CubicKeyframe(1, duration: 0.24, startVelocity: 0, endVelocity: 0)
            }
        }
    }
}

/// A circle on `NotchBottomEdge` at a fraction of its length. Animates with the edge,
/// so a dot riding a morphing silhouette stays on it.
struct EdgeDot: Shape {
    var edge: NotchBottomEdge
    var at: CGFloat
    var diameter: CGFloat

    var animatableData: AnimatablePair<NotchBottomEdge.AnimatableData,
                                       AnimatablePair<CGFloat, CGFloat>> {
        get { .init(edge.animatableData, .init(at, diameter)) }
        set {
            edge.animatableData = newValue.first
            at = newValue.second.first
            diameter = newValue.second.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let end = edge.path(in: rect).trimmedPath(from: 0, to: min(1, max(0.0001, at)))
            .currentPoint ?? CGPoint(x: rect.midX, y: rect.maxY)
        return Path(ellipseIn: CGRect(x: end.x - diameter / 2, y: end.y - diameter / 2,
                                      width: diameter, height: diameter))
    }
}

/// Just the bottom edge of `NotchShape` as an open path. Trimmed and stroked, it
/// draws playback progress along the panel's own silhouette.
/// on a separate track.
struct NotchBottomEdge: Shape {
    var width: CGFloat
    var height: CGFloat
    var bottomCornerRadius: CGFloat
    /// Half the stroke's width, so the line's outer edge lands on the silhouette rather
    /// than straddling it. Animated, because the width swells on hover and grab.
    var inset: CGFloat = 0

    /// The radius interpolates with the frame; otherwise it jumps on the first frame of
    /// an expand and the trace peels away from the silhouette.
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
        // Must match `NotchShape.simplePath`, including the `height / 2` clamp. The inset
        // shrinks the corner with the frame: clamping the shell's radius against an
        // inset frame translates the corner instead of offsetting it, leaving the stroke's
        // outer boundary up to `inset * (sqrt(2) - 1)` inside the silhouette at 45 degrees.
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
