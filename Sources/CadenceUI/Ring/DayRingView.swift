// The day ring: one ring on purpose, so it cannot read as three goals to fill (docs/SPEC.md section 5.2).
import CadenceCore
import SwiftUI

public struct DayRingView: View {
    public enum Style: Sendable {
        case full, compact
    }

    let tasks: [TaskStatus]
    let beads: [Family: Int]
    let sealed: Bool
    let size: CGFloat
    let style: Style

    public init(tasks: [TaskStatus], beads: [Family: Int], sealed: Bool, size: CGFloat, style: Style = .full) {
        self.tasks = tasks
        self.beads = beads
        self.sealed = sealed
        self.size = size
        self.style = style
    }

    public init(state: DayState, size: CGFloat, style: Style = .full) {
        let counts = Dictionary(uniqueKeysWithValues: state.ring.beads.map { ($0.family, $0.count) })
        self.init(tasks: state.tasks.map(\.status), beads: counts, sealed: state.isSealed, size: size, style: style)
    }

    private var layout: DayRingLayout { DayRingLayout(tasks: tasks, beads: beads) }
    private var scale: CGFloat { size / CadenceRingTokens.viewBox }
    private var figureToken: TypeToken {
        let tokens = CadenceRingTokens.self
        let base = CadenceType.heroFigure
        let points = (style == .compact ? tokens.figureCompact : tokens.figure) * scale
        return TypeToken(
            name: base.name, face: base.face, size: points, lineHeight: points, weight: base.weight,
            tracking: base.tracking, sample: base.sample)
    }

    /// Planned done as a fraction. Nothing planned has no fraction, and unknown is not zero (section 6.6).
    var centre: String {
        let kept = tasks.filter { $0 != .moved }
        guard !kept.isEmpty else { return "-" }
        return "\(kept.filter { $0 == .done }.count)/\(kept.count)"
    }

    /// The words under the figure, kept only where they clear the type floor.
    var caption: String? {
        let tokens = CadenceRingTokens.self
        guard style == .full, CadenceType.caption.size <= tokens.captionFit * scale else { return nil }
        if sealed { return "sealed" }
        return tasks.contains { $0 != .moved } ? "planned done" : nil
    }

    public var body: some View {
        ZStack {
            Canvas { context, _ in draw(in: &context) }
            VStack(spacing: 0) {
                Text(centre).cadenceType(figureToken).foregroundStyle(CadenceColor.ink.color)
                if let caption {
                    Text(caption).cadenceType(CadenceType.caption).foregroundStyle(CadenceColor.ink3.color)
                }
            }
        }
        .frame(width: size, height: size)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
    }

    /// The ring's VoiceOver summary: identity never rests on colour or shape alone.
    public var accessibilitySummary: String {
        let kept = tasks.filter { $0 != .moved }
        var parts: [String] = []
        if kept.isEmpty {
            parts.append("Nothing planned")
        } else {
            parts.append("\(kept.filter { $0 == .done }.count) of \(kept.count) planned done")
            for (status, word) in [(TaskStatus.slipped, "slipped"), (.dropped, "dropped"), (.open, "open")] {
                let count = kept.filter { $0 == status }.count
                if count > 0 { parts.append("\(count) \(word)") }
            }
        }
        for family in Family.ringOrder {
            if let count = beads[family], count > 0 { parts.append("\(count) \(Self.word(family))") }
        }
        if sealed { parts.append("sealed") }
        return parts.joined(separator: ", ")
    }

    private static func word(_ family: Family) -> String {
        switch family {
        case .delivery: "delivery"
        case .review: "review"
        case .initiative: "initiative"
        case .ownership: "ownership"
        case .leadership: "leadership"
        case .ai: "AI"
        case .presence: "presence"
        }
    }

    // MARK: Drawing

    private func point(radius: CGFloat, degrees: CGFloat) -> CGPoint {
        let t = degrees * .pi / 180
        let half = CadenceRingTokens.viewBox / 2
        return CGPoint(x: (half + radius * sin(t)) * scale, y: (half - radius * cos(t)) * scale)
    }

    private func arc(start: CGFloat, end: CGFloat) -> Path {
        var path = Path()
        let half = CadenceRingTokens.viewBox / 2 * scale
        // Canvas angles run from three o'clock, and clockwise on screen reads as false in its flipped space.
        path.addArc(
            center: CGPoint(x: half, y: half), radius: CadenceRingTokens.segmentRadius * scale,
            startAngle: .degrees(Double(start) - 90), endAngle: .degrees(Double(end) - 90), clockwise: false)
        return path
    }

    private func draw(in context: inout GraphicsContext) {
        let tokens = CadenceRingTokens.self
        let ink = CadenceColor.ink.color
        let width = tokens.segmentWidth * scale
        if sealed {
            context.stroke(arc(start: 0, end: 360), with: .color(ink), lineWidth: tokens.hairline * scale)
        }
        if layout.segments.isEmpty {
            context.stroke(arc(start: 0, end: 360), with: .color(ink.opacity(tokens.emptyOpacity)), lineWidth: width)
        }
        for segment in layout.segments {
            let path = arc(start: segment.start, end: segment.end)
            switch segment.status {
            case .done:
                context.stroke(path, with: .color(ink), lineWidth: width)
            case .slipped:
                let style = StrokeStyle(lineWidth: width, dash: [tokens.dash * scale, tokens.dashGap * scale])
                context.stroke(path, with: .color(ink), style: style)
            case .dropped:
                context.stroke(path, with: .color(CadenceColor.other.color), lineWidth: width)
            case .open, .moved:
                context.stroke(path, with: .color(ink.opacity(tokens.openOpacity)), lineWidth: width)
            }
        }
        let size = (style == .compact ? tokens.beadSizeCompact : tokens.beadSize) * scale
        for bead in layout.beads {
            draw(bead.family, at: point(radius: tokens.beadRadius, degrees: bead.angle), size: size, in: &context)
        }
    }

    private func draw(_ family: Family, at c: CGPoint, size s: CGFloat, in context: inout GraphicsContext) {
        let tokens = CadenceRingTokens.self
        let tint = GraphicsContext.Shading.color(CadenceColor.family(family).color)
        func dot(_ r: CGFloat) -> Path { Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)) }
        switch CadenceSymbols.shape(for: family) {
        case .circle:
            context.fill(dot(s), with: tint)
        case .ring:
            let stroke = tokens.reviewStroke * scale
            context.stroke(dot(s - stroke / 2), with: tint, lineWidth: stroke)
        case .diamond:
            var path = Path()
            let r = s * 1.25
            path.addLines([CGPoint(x: c.x, y: c.y - r), CGPoint(x: c.x + r, y: c.y), CGPoint(x: c.x, y: c.y + r), CGPoint(x: c.x - r, y: c.y)])
            path.closeSubpath()
            context.fill(path, with: tint)
        case .square:
            let r = s * 0.88
            let corner = CadenceRadius.mark / 2
            context.fill(Path(roundedRect: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2), cornerRadius: corner), with: tint)
        case .triangle:
            var path = Path()
            path.addLines([
                CGPoint(x: c.x, y: c.y - s * 1.2), CGPoint(x: c.x + s * 1.15, y: c.y + s * 0.85),
                CGPoint(x: c.x - s * 1.15, y: c.y + s * 0.85),
            ])
            path.closeSubpath()
            context.fill(path, with: tint)
        case .smallDot:
            context.fill(dot(s * 0.6), with: tint)
        case .none:
            break
        }
    }
}
