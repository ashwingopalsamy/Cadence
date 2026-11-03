// Tempo, the character (docs/SPEC.md sections 5.3 and 5.7). The gesture plays for 8 beats when the view appears or the
// spec changes, the water sloshes with it and bubbles rise on lively days; then Tempo holds still. The held pose reads
// no clock, so an idle Tempo costs no CPU. Reduce Motion shows the held pose with level water from the start.
import SwiftUI

public struct TempoView: View {
    let spec: TempoSpec
    let size: CGFloat
    let label: String?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var playing: Date?

    /// Tempo drawn `size` points wide; it is 1.24 times as tall. Decorative unless given a label for VoiceOver.
    public init(_ spec: TempoSpec, size: CGFloat, label: String? = nil) {
        self.spec = spec
        self.size = size
        self.label = label
    }

    /// The height for a given width: the drawing's box is 100 by 124.
    public static func height(forWidth width: CGFloat) -> CGFloat {
        width * CadenceTempoTokens.viewBox.height / CadenceTempoTokens.viewBox.width
    }

    public var body: some View {
        content
            .frame(width: size, height: Self.height(forWidth: size))
            .task(id: spec) { await play() }
            .modifier(TempoAccessibility(label: label))
    }

    @ViewBuilder private var content: some View {
        if let start = playing, !reduceMotion {
            TimelineView(.animation) { timeline in
                TempoCanvas(spec: spec, elapsed: timeline.date.timeIntervalSince(start))
            }
        } else {
            TempoCanvas(spec: spec, elapsed: nil)
        }
    }

    /// Runs the gesture once, then lets the timeline go.
    private func play() async {
        let duration = spec.playDuration
        guard duration > 0, !reduceMotion else {
            playing = nil
            return
        }
        playing = .now
        try? await Task.sleep(for: .seconds(duration))
        if !Task.isCancelled { playing = nil }
    }
}

/// One frame of Tempo. With no elapsed time it is the held pose. Like the prototype's SVG, it draws past its box
/// (a wrench, a plug, a body lying down), so the canvas reaches beyond the frame by an overflow margin on every side.
struct TempoCanvas: View {
    let spec: TempoSpec
    let elapsed: TimeInterval?

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let margin = width * CadenceTempoTokens.overflow / CadenceTempoTokens.viewBox.width
            Canvas { context, _ in
                var context = context
                context.translateBy(x: margin, y: margin)
                TempoRenderer(spec: spec, elapsed: elapsed).draw(in: context, size: CGSize(width: width, height: proxy.size.height))
            }
            .frame(width: width + 2 * margin, height: proxy.size.height + 2 * margin)
            .offset(x: -margin, y: -margin)
        }
    }
}

private struct TempoAccessibility: ViewModifier {
    let label: String?

    func body(content: Content) -> some View {
        if let label {
            content.accessibilityElement().accessibilityLabel(label).accessibilityAddTraits(.isImage)
        } else {
            content.accessibilityHidden(true)
        }
    }
}

/// The app's face, for notifications and the capture bar: Tempo's "icon" pose on a soft tile.
public struct TempoAppIcon: View {
    let size: CGFloat
    let label: String?

    public init(size: CGFloat, label: String? = nil) {
        self.size = size
        self.label = label
    }

    public var body: some View {
        let tile = CadenceTempoTokens.Tile.self
        // The drawing fits the tile's height, centred, as an SVG that meets its box.
        let width = size * CadenceTempoTokens.viewBox.width / CadenceTempoTokens.viewBox.height
        TempoCanvas(spec: TempoSpec(pose: .icon), elapsed: nil)
            .frame(width: width, height: size)
            .frame(width: size, height: size)
            .background(LinearGradient(colors: [tile.top, tile.bottom], startPoint: Self.start, endPoint: Self.end))
            .clipShape(RoundedRectangle(cornerRadius: size * tile.cornerFraction, style: .circular))
            .modifier(TempoAccessibility(label: label))
    }

    /// The ends of a CSS gradient line at the tile's angle, for a square: it runs through the centre and is long enough
    /// that the corners take the end colours.
    static var start: UnitPoint { point(-1) }
    static var end: UnitPoint { point(1) }

    private static func point(_ sign: Double) -> UnitPoint {
        let a = CadenceTempoTokens.Tile.angle * .pi / 180
        let (dx, dy) = (sin(a), -cos(a))
        let half = (abs(dx) + abs(dy)) / 2
        return UnitPoint(x: 0.5 + sign * dx * half, y: 0.5 + sign * dy * half)
    }
}
