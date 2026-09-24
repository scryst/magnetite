import SwiftUI

/// Single-line text that scrolls only when it actually overflows.
///
/// Design constraints, each of which cost a debugging round:
///
///  * **It must lay out like ordinary text.** An earlier version was a
///    `GeometryReader`, which has no ideal width — inside an `HStack` the stack
///    handed it zero and the title vanished while the same view worked fine alone
///    in a `VStack`. The visible element here is a plain `Text` with
///    `maxWidth: .infinity`, so it claims space exactly as a label would.
///  * **It must never render blank.** The base `Text` is always present and
///    truncating; scrolling is an *overlay* on top, so any measurement failure
///    degrades to a truncated title rather than an empty row.
///  * **It must not be baseline-aligned by its container.** Put it in
///    `HStack(alignment: .center)`, never `.firstTextBaseline`.
struct MarqueeText: View {
    let text: String
    var font: Font = .system(size: 13, weight: .semibold)
    /// Stillness at each end of a pass.
    var hold: Double = 1.9
    var pointsPerSecond: Double = 22

    @ViewState private var textWidth: CGFloat = 0
    @ViewState private var boxWidth: CGFloat = 0
    @ViewState private var shifted = false
    /// The environment value, not `Motion.reduceMotion`: the static is invisible
    /// to SwiftUI invalidation, so flipping Reduce Motion mid-session never
    /// re-evaluated an on-screen marquee — a scrolling title kept scrolling (and
    /// a truncated one stayed truncated) until the next track replaced the view.
    /// The environment is what makes the setting reach a marquee that is already
    /// on screen.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var overflow: CGFloat { max(0, textWidth - boxWidth) }
    /// The two gates, taken from `ChromeRules` so `chromecheck` asserts the same
    /// predicate the view applies.
    ///
    /// They used to be keyed on different things — the label on `scrolls` alone,
    /// the scroller on `scrolls && !reduceMotion` — so with Reduce Motion on, any
    /// title wider than its column rendered as NOTHING: the static text faded out
    /// for an overlay that was never drawn. "Never replace the interface with an
    /// inert or ambiguous state"; a blank row where the song title goes is both.
    private var hidesLabel: Bool {
        ChromeRules.marqueeHidesStaticLabel(textWidth: textWidth, boxWidth: boxWidth,
                                            reduceMotion: reduceMotion)
    }
    private var showsScroller: Bool {
        ChromeRules.marqueeShowsScroller(textWidth: textWidth, boxWidth: boxWidth,
                                         reduceMotion: reduceMotion)
    }
    private var travel: Double { max(0.8, Double(overflow) / pointsPerSecond) }

    var body: some View {
        Text(text)
            .font(font)
            .lineLimit(1)
            .truncationMode(.tail)
            // Hidden while the scrolling overlay is up, but still driving layout.
            .opacity(hidesLabel ? 0 : 1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background { measurement }
            .overlay(alignment: .leading) { scroller }
            .onChange(of: text) { _, _ in
                shifted = false
                DispatchQueue.main.async { shifted = showsScroller }
            }
            .onChange(of: showsScroller) { _, now in shifted = now }
            .onAppear { shifted = showsScroller }
    }

    /// Two zero-cost probes: the container's width, and the text's intrinsic width.
    private var measurement: some View {
        ZStack(alignment: .leading) {
            Color.clear
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { boxWidth = $0 }
            Text(text).font(font).lineLimit(1).fixedSize()
                .hidden()
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { textWidth = $0 }
        }
    }

    @ViewBuilder
    private var scroller: some View {
        if showsScroller {
            Text(text)
                .font(font)
                .lineLimit(1)
                .fixedSize()
                .offset(x: shifted ? -overflow : 0)
                .animation(.easeInOut(duration: travel)
                    .delay(hold)
                    .repeatForever(autoreverses: true),
                           value: shifted)
                .frame(width: boxWidth, alignment: .leading)
                .clipped()
                .mask {
                    // Dissolve at the trailing edge instead of a hard cut.
                    LinearGradient(
                        stops: [
                            .init(color: .black, location: 0),
                            .init(color: .black, location: 0.88),
                            .init(color: .clear, location: 1),
                        ],
                        startPoint: .leading, endPoint: .trailing)
                }
                .allowsHitTesting(false)
        }
    }
}
