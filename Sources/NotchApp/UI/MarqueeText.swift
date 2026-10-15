import SwiftUI

/// Single-line text that scrolls only when it actually overflows.
///
/// The visible element is a plain `Text` with `maxWidth: .infinity`, so it lays out
/// like an ordinary label. A `GeometryReader` has no ideal width and collapses to
/// zero inside an `HStack`. The base `Text` is always present and truncating and
/// the scroll is an overlay, so a failed measurement degrades to a truncated title
/// rather than a blank row.
///
/// Place it in `HStack(alignment: .center)`; baseline alignment misplaces it.
struct MarqueeText: View {
    let text: String
    var font: Font = .system(size: 13, weight: .semibold)
    /// Links share the title's layout and scrolling path, including its fallback.
    var attributedText: AttributedString? = nil
    /// Stillness at each end of a pass.
    var hold: Double = 1.9
    var pointsPerSecond: Double = 22

    @ViewState private var textWidth: CGFloat = 0
    @ViewState private var boxWidth: CGFloat = 0
    @ViewState private var shifted = false
    /// The environment value rather than `Motion.reduceMotion`: a static is invisible to
    /// SwiftUI invalidation, so toggling Reduce Motion would not reach a marquee that
    /// is already on screen.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var overflow: CGFloat { max(0, textWidth - boxWidth) }
    /// Both gates come from `ChromeRules`, so `chromecheck` asserts the predicate the
    /// view applies. They must agree: if the label hid on `scrolls` alone while the
    /// scroller also required `!reduceMotion`, an overflowing title would render as
    /// nothing under Reduce Motion.
    private var hidesLabel: Bool {
        ChromeRules.marqueeHidesStaticLabel(textWidth: textWidth, boxWidth: boxWidth,
                                            reduceMotion: reduceMotion)
    }
    private var showsScroller: Bool {
        ChromeRules.marqueeShowsScroller(textWidth: textWidth, boxWidth: boxWidth,
                                         reduceMotion: reduceMotion)
    }
    private var travel: Double { max(0.8, Double(overflow) / pointsPerSecond) }
    private var label: Text { attributedText.map { Text($0) } ?? Text(text) }

    var body: some View {
        label
            .font(font)
            .lineLimit(1)
            .truncationMode(.tail)
            // Hidden while the scrolling overlay is up, but still drives layout.
            .opacity(hidesLabel ? 0 : 1)
            .allowsHitTesting(attributedText == nil || !hidesLabel)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background { measurement }
            .overlay(alignment: .leading) { scroller }
            .onChange(of: text) { _, _ in
                shifted = false
                DispatchQueue.main.async { shifted = showsScroller }
            }
            .onChange(of: showsScroller) { _, now in shifted = now }
            .onAppear { shifted = showsScroller }
            // Under Reduce Motion an overflowing line only truncates; the tooltip is the way
            // to read all of it.
            .help(overflow > 0 ? text : "")
    }

    /// Probes for the container's width and the text's intrinsic width.
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
            label
                .font(font)
                .lineLimit(1)
                .fixedSize()
                .offset(x: shifted ? -overflow : 0)
                .animation(.easeInOut(duration: travel)
                    .delay(hold)
                    .repeatForever(autoreverses: true),
                           value: shifted)
                .frame(width: boxWidth, alignment: .leading)
                .contentShape(Rectangle())
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
                .allowsHitTesting(attributedText != nil)
                // The base label already speaks this line.
                .accessibilityHidden(true)
        }
    }
}
