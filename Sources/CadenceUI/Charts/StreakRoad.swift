// The streak road (docs/SPEC.md section 5.4): a journey, not a counter. The road winds to the next milestone, filled as
// far as the run of sealed workdays reaches, with every milestone on it a numbered stop. Days off pause the run and never
// break it, so the road has no breaks to show.
import CadenceCore
import SwiftUI

public struct StreakRoadFigures: ChartFigures {
    /// Streak milestones (sections 5.4 and 5.6).
    public static let milestones = [5, 10, 20, 50, 100, 200]

    /// Workdays sealed in a row.
    public var current: Int
    /// Days off inside the run: they paused it.
    public var paused: Int

    public init(current: Int, paused: Int = 0) {
        self.current = max(0, current)
        self.paused = max(0, paused)
    }

    public init(_ streak: Streak) {
        self.init(current: streak.current, paused: streak.pausedBy.count)
    }

    public var passed: [Int] { Self.milestones.filter { $0 <= current } }
    /// The next milestone, or nil past the last.
    public var next: Int? { Self.milestones.first { $0 > current } }
    /// How many workdays the road spans: to the next milestone, or the run itself past the last.
    public var length: Int { next ?? max(current, Self.milestones.last ?? current) }
    /// The stops on the road.
    public var stops: [Int] { Self.milestones.filter { $0 <= length } }

    public var summary: String {
        var text = String(localized: "\(ChartText.count(current, String(localized: "workday"))) sealed in a row.")
        if !passed.isEmpty { text += String(localized: " Milestones passed: \(ChartText.list(passed.map(String.init))).") }
        if let next { text += passed.isEmpty ? String(localized: " The first milestone is \(next).") : String(localized: " The next is \(next).") }
        if paused > 0 { text += String(localized: " Days off paused it \(paused == 1 ? String(localized: "once") : String(localized: "\(paused) times")) and never broke it.") }
        return text
    }

    public var table: ChartTable {
        ChartTable(
            columns: [String(localized: "Streak"), String(localized: "Workdays")],
            rows: [
                [String(localized: "Sealed in a row"), String(current)],
                [String(localized: "Milestones passed"), passed.isEmpty ? ChartText.unknown : passed.map(String.init).joined(separator: ", ")],
                [String(localized: "Next milestone"), next.map(String.init) ?? ChartText.unknown],
                [String(localized: "Days off inside the run"), String(paused)],
            ])
    }
}

public struct StreakRoad: View {
    let figures: StreakRoadFigures

    public init(_ figures: StreakRoadFigures) {
        self.figures = figures
    }

    enum Metrics {
        static let stroke = CadenceSpace.s16
        /// Half the gap between two rows of road.
        static let turn = CadenceSpace.s20
        static let rows = 3
        static let stop = CadenceSize.chip
        static let head = CadenceSize.controlToolbar
        static let ring = CadenceSpace.s2
        static var height: CGFloat { CGFloat(rows - 1) * 2 * turn + head }
    }

    public var body: some View {
        GeometryReader { proxy in
            let road = Road(width: proxy.size.width)
            ZStack(alignment: .topLeading) {
                road.path.stroke(CadenceColor.track.color, style: StrokeStyle(lineWidth: Metrics.stroke, lineCap: .round, lineJoin: .round))
                if figures.current > 0 {
                    road.path.trimmedPath(from: 0, to: fraction(figures.current))
                        .stroke(CadenceColor.brand.color, style: StrokeStyle(lineWidth: Metrics.stroke, lineCap: .round, lineJoin: .round))
                }
                ForEach(figures.stops.filter { $0 != figures.current }, id: \.self) { stop in
                    let passed = stop <= figures.current
                    Text(String(stop))
                        .cadenceType(ChartType.day)
                        .foregroundStyle(passed ? CadenceColor.onBrand.color : CadenceColor.ink2.color)
                        .frame(width: Metrics.stop, height: Metrics.stop)
                        .background(Circle().fill(passed ? CadenceColor.brand.color : CadenceColor.card.color))
                        .overlay(Circle().strokeBorder(passed ? CadenceColor.card.color : CadenceColor.ink3.color, lineWidth: Metrics.ring))
                        .position(road.point(at: fraction(stop)))
                }
                if figures.current > 0 {
                    Text(String(figures.current))
                        .cadenceType(ChartType.value)
                        .foregroundStyle(CadenceColor.onBrand.color)
                        .frame(minWidth: Metrics.head, minHeight: Metrics.head)
                        .background(Capsule().fill(CadenceColor.brand.color))
                        .overlay(Capsule().strokeBorder(CadenceColor.card.color, lineWidth: Metrics.ring))
                        .fixedSize()
                        .position(road.point(at: fraction(figures.current)))
                }
            }
        }
        .frame(height: Metrics.height)
        .chartAccessibility(figures.summary)
    }

    private func fraction(_ workdays: Int) -> CGFloat {
        CGFloat(min(workdays, figures.length)) / CGFloat(max(1, figures.length))
    }

    /// Three rows of road joined by half turns, inset so the head and the caps stay inside the frame.
    struct Road {
        let width: CGFloat

        private var inset: CGFloat { Metrics.head / 2 }
        private var r: CGFloat { Metrics.turn }
        private var left: CGFloat { inset + r }
        private var right: CGFloat { width - inset - r }
        private func row(_ n: Int) -> CGFloat { inset + CGFloat(n) * 2 * r }

        /// Row 0 left to right, a turn down on the right, row 1 back, a turn down on the left, row 2 to the end.
        private var pieces: [(CGFloat, (CGFloat) -> CGPoint)] {
            let straight0 = right - inset
            let straight1 = right - left
            let straight2 = width - inset - left
            let arc = CGFloat.pi * r
            return [
                (straight0, { CGPoint(x: inset + $0, y: row(0)) }),
                (arc, { d in
                    let a = -CGFloat.pi / 2 + d / r
                    return CGPoint(x: right + r * cos(a), y: row(0) + r + r * sin(a))
                }),
                (straight1, { CGPoint(x: right - $0, y: row(1)) }),
                (arc, { d in
                    let a = -CGFloat.pi / 2 - d / r
                    return CGPoint(x: left + r * cos(a), y: row(1) + r + r * sin(a))
                }),
                (straight2, { CGPoint(x: left + $0, y: row(2)) }),
            ]
        }

        var total: CGFloat { pieces.map(\.0).reduce(0, +) }

        /// The point `fraction` of the way along the road.
        func point(at fraction: CGFloat) -> CGPoint {
            var d = max(0, min(1, fraction)) * total
            for (length, at) in pieces {
                if d <= length { return at(d) }
                d -= length
            }
            return CGPoint(x: width - inset, y: row(2))
        }

        var path: Path {
            var path = Path()
            path.move(to: CGPoint(x: inset, y: row(0)))
            path.addLine(to: CGPoint(x: right, y: row(0)))
            path.addArc(center: CGPoint(x: right, y: row(0) + r), radius: r, startAngle: .degrees(-90), endAngle: .degrees(90), clockwise: false)
            path.addLine(to: CGPoint(x: left, y: row(1)))
            path.addArc(center: CGPoint(x: left, y: row(1) + r), radius: r, startAngle: .degrees(-90), endAngle: .degrees(90), clockwise: true)
            path.addLine(to: CGPoint(x: width - inset, y: row(2)))
            return path
        }
    }
}
