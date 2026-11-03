// The rhythm band (docs/SPEC.md sections 5.1 and 6.5): items logged per counted workday against your usual range, each
// point read against the range as it stood that day, with the median as the line between the band's two tones. Days
// that are not counted are gaps, never zeros: the line breaks over them and a dotted thread joins across. Today sits at
// the right, read against usual by now. It is drawn in the hero's colour world.
import CadenceCore
import SwiftUI

public struct RhythmFigures: ChartFigures {
    /// The dates before today, oldest first. `items` is nil on a day that is not counted.
    public var points: [RhythmPoint]
    /// Items logged today, or nil when nothing is logged yet.
    public var today: Int?
    /// The usual day, over the last 20 counted workdays.
    public var usual: UsualRange?
    /// Usual by now, at `clock`.
    public var byNow: UsualRange?
    /// "14:20", the time usual by now is read at.
    public var clock: String
    /// A source feeding the count is behind: every comparison is suppressed.
    public var stale: Bool
    let dates: ChartDates

    /// `rhythm.points` ends on the reference day, which is today, so it is held apart.
    public init(rhythm: Rhythm, clock: String, stale: Bool = false, locale: Locale) {
        points = Array(rhythm.points.dropLast())
        today = rhythm.today > 0 ? rhythm.today : nil
        usual = rhythm.usual
        byNow = stale ? nil : rhythm.byNow
        self.clock = clock
        self.stale = stale
        dates = ChartDates(locale: locale)
    }

    public static func == (a: RhythmFigures, b: RhythmFigures) -> Bool {
        a.points == b.points && a.today == b.today && a.usual == b.usual && a.byNow == b.byNow && a.clock == b.clock
            && a.stale == b.stale && a.dates.locale == b.dates.locale
    }

    static func range(_ range: UsualRange?) -> String { range.map { String(localized: "\($0.low) to \($0.high)") } ?? ChartText.unknown }

    /// True when the point lies inside the range that stood on its day. A point with no range yet is not outside.
    static func inside(_ point: RhythmPoint) -> Bool {
        guard let items = point.items, let usual = point.usual else { return true }
        return items >= usual.low && items <= usual.high
    }

    /// The line under the band: the usual day and usual by now, or why there is no comparison.
    public var caption: String {
        if stale { return String(localized: "A source is behind, so today is not compared.") }
        guard let usual else { return String(localized: "Still learning your usual range.") }
        var text = String(localized: "Usual day: \(usual.low) to \(usual.high).")
        if let byNow { text += String(localized: " Usual by \(clock): \(byNow.low) to \(byNow.high).") }
        return text
    }

    public var summary: String {
        var text = today.map { String(localized: "\(ChartText.count($0, String(localized: "item"))) logged today.") } ?? String(localized: "Nothing logged yet today.")
        if stale { return text + String(localized: " A source is behind, so there is no comparison.") }
        guard let usual else { return text + String(localized: " Still learning your usual range.") }
        text += String(localized: " A usual day is \(usual.low) to \(usual.high)")
        if let byNow { text += String(localized: ", and usually \(byNow.low) to \(byNow.high) by \(clock)") }
        let outside = points.filter { !Self.inside($0) }.count
        return text + ". " + (outside == 0 ? String(localized: "Every earlier day was inside its usual range.") : String(localized: "\(ChartText.count(outside, String(localized: "earlier day"))) fell outside its usual range."))
    }

    public var table: ChartTable {
        var rows = points.map { point in
            [dates.weekdayShort(point.date), point.items.map(String.init) ?? String(localized: "Not counted"), Self.range(point.usual)]
        }
        rows.append([String(localized: "Today"), ChartText.value(today), byNow.map { String(localized: "\($0.low) to \($0.high) by \(clock)") } ?? Self.range(usual)])
        return ChartTable(columns: [String(localized: "Day"), String(localized: "Items logged"), String(localized: "Usual range")], rows: rows)
    }
}

/// The band on a hero. `world` gives the ground's two band tones and its ink.
public struct RhythmBand: View {
    let figures: RhythmFigures
    let world: ColorWorld
    let height: CGFloat
    @Environment(\.colorSchemeContrast) private var contrast

    public static let defaultHeight = CadenceSpace.s48 * 3 + CadenceSpace.s4

    public init(_ figures: RhythmFigures, world: ColorWorld, height: CGFloat = RhythmBand.defaultHeight) {
        self.figures = figures
        self.world = world
        self.height = height
    }

    private enum Mark {
        static let dot = CadenceSpace.s12
        static let dotRing = CadenceSpace.s2
        static let today = CadenceSpace.s20
        static let todayRing = CadenceSpace.s4
        static let bracket = CadenceSpace.s6
        static let bracketOpacity = 0.38
        static let line = CadenceSpace.s2
        static let thread: [CGFloat] = [CadenceSpace.s2, CadenceSpace.s4]
        /// Room at the top and bottom of the plot, so marks are never cut.
        static let inset = CadenceSpace.s12
        /// The y axis prints a tick every this many items.
        static let tickStep = 4
    }

    public var body: some View {
        VStack(spacing: CadenceSpace.s4) {
            GeometryReader { proxy in
                let plot = Plot(figures: figures, size: proxy.size)
                ZStack(alignment: .topLeading) {
                    bands(plot)
                    lines(plot)
                    ForEach(plot.ticks, id: \.self) { tick in
                        Text(String(tick))
                            .cadenceType(ChartType.axis)
                            .foregroundStyle(world.ink.color.opacity(0.9))
                            .position(x: CadenceSpace.s12, y: plot.y(Double(tick)))
                    }
                    dots(plot)
                    todayMark(plot)
                }
            }
            .frame(height: height)
            HStack(alignment: .firstTextBaseline, spacing: CadenceSpace.s8) {
                Text(figures.points.first.map { figures.dates.short($0.date) } ?? "")
                Spacer(minLength: CadenceSpace.s8)
                Text(figures.caption).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: CadenceSpace.s8)
                Text("Today")
            }
            .cadenceType(ChartType.band)
            .foregroundStyle(world.ink.color)
            .padding(.horizontal, CadenceSpace.s24)
        }
        .chartAccessibility(figures.summary)
    }

    @ViewBuilder private func bands(_ plot: Plot) -> some View {
        ForEach(plot.bandRuns, id: \.self) { run in
            plot.area(run, upper: \.high, lower: \.median).fill(world.a.color)
            plot.area(run, upper: \.median, lower: \.low).fill(world.b.color)
            // Increase Contrast: the band gains an edge (section 6.7).
            if contrast == .increased {
                plot.area(run, upper: \.high, lower: \.low)
                    .stroke(world.ink.color.opacity(ChartMetrics.edgeOpacity), lineWidth: ChartMetrics.edge)
            }
        }
    }

    @ViewBuilder private func lines(_ plot: Plot) -> some View {
        plot.solid.stroke(world.ink.color, style: StrokeStyle(lineWidth: Mark.line, lineCap: .round, lineJoin: .round))
        plot.threads.stroke(world.ink.color.opacity(0.6), style: StrokeStyle(lineWidth: Mark.line / 2, lineCap: .round, dash: Mark.thread))
    }

    @ViewBuilder private func dots(_ plot: Plot) -> some View {
        ForEach(Array(figures.points.enumerated()), id: \.offset) { index, point in
            if let items = point.items {
                let filled = RhythmFigures.inside(point)
                Circle()
                    .fill(filled ? world.ink.color : Color.clear)
                    .overlay(Circle().strokeBorder(world.ink.color, lineWidth: Mark.dotRing))
                    .frame(width: Mark.dot, height: Mark.dot)
                    .position(x: plot.x(index), y: plot.y(Double(items)))
            }
        }
    }

    @ViewBuilder private func todayMark(_ plot: Plot) -> some View {
        let x = plot.x(figures.points.count)
        if let byNow = figures.byNow {
            Capsule()
                .fill(world.ink.color.opacity(Mark.bracketOpacity))
                .frame(width: Mark.bracket, height: max(Mark.bracket, plot.y(Double(byNow.low)) - plot.y(Double(byNow.high))))
                .position(x: x, y: (plot.y(Double(byNow.low)) + plot.y(Double(byNow.high))) / 2)
        }
        let y = plot.y(figures.today.map(Double.init) ?? plot.middle)
        Group {
            if figures.today == nil || figures.stale {
                Circle().strokeBorder(world.ink.color, style: StrokeStyle(lineWidth: Mark.dotRing, dash: Mark.thread.map { $0 * 2 }))
            } else {
                Circle().fill(Color.white).overlay(Circle().strokeBorder(world.ink.color, lineWidth: Mark.todayRing))
            }
        }
        .frame(width: Mark.today, height: Mark.today)
        .position(x: x, y: y)
        Text(figures.today.map { String(localized: "Today, \($0)") } ?? String(localized: "Today"))
            .cadenceType(ChartType.bandToday)
            .foregroundStyle(world.ink.color)
            .padding(.horizontal, CadenceSpace.s4)
            .background(RoundedRectangle(cornerRadius: CadenceSpace.s4).fill(world.bg.color))
            .fixedSize()
            .position(x: x - CadenceSpace.s48, y: max(CadenceSpace.s8, y - CadenceSpace.s24))
    }

    /// The geometry of one drawing: x by date so gaps keep their width, y by count over one shared scale.
    struct Plot {
        let figures: RhythmFigures
        let size: CGSize

        var slots: Int { figures.points.count + 1 }

        var values: [Double] {
            figures.points.flatMap { point -> [Double] in
                [point.items, point.usual?.low, point.usual?.high].compactMap { $0.map(Double.init) }
            } + [figures.today, figures.byNow?.low, figures.byNow?.high].compactMap { $0.map(Double.init) }
        }

        var top: Double { max(Double(Mark.tickStep * 2), values.max() ?? 0) + 0.5 }
        var bottom: Double { max(0, (values.min() ?? 0) - 0.5) }
        var middle: Double { figures.usual.map { Double($0.low + $0.high) / 2 } ?? (top + bottom) / 2 }

        func x(_ index: Int) -> CGFloat { (CGFloat(index) + 0.5) / CGFloat(slots) * size.width }

        func y(_ value: Double) -> CGFloat {
            let usable = size.height - Mark.inset * 2
            return Mark.inset + usable * CGFloat((top - value) / max(1, top - bottom))
        }

        var ticks: [Int] {
            stride(from: Mark.tickStep, to: Int(top), by: Mark.tickStep).filter { Double($0) > bottom }
        }

        /// Runs of consecutive dates that have a range, as index ranges.
        var bandRuns: [ClosedRange<Int>] {
            var runs: [ClosedRange<Int>] = []
            var start: Int?
            for (i, point) in figures.points.enumerated() {
                if point.usual != nil {
                    if start == nil { start = i }
                } else if let s = start {
                    runs.append(s...(i - 1))
                    start = nil
                }
            }
            if let s = start { runs.append(s...(figures.points.count - 1)) }
            return runs
        }

        /// The band between two edges of the range over a run, reaching to the chart's edge at either end.
        func area(_ run: ClosedRange<Int>, upper: KeyPath<UsualRange, Int>, lower: KeyPath<UsualRange, Int>) -> Path {
            func edgeX(_ i: Int) -> CGFloat {
                i == 0 ? 0 : i == slots - 2 && run.upperBound == i ? size.width : x(i)
            }
            var path = Path()
            let indices = Array(run)
            for (n, i) in indices.enumerated() {
                guard let usual = figures.points[i].usual else { continue }
                let p = CGPoint(x: edgeX(i), y: y(Double(usual[keyPath: upper])))
                if n == 0 { path.move(to: p) } else { path.addLine(to: p) }
            }
            for i in indices.reversed() {
                guard let usual = figures.points[i].usual else { continue }
                path.addLine(to: CGPoint(x: edgeX(i), y: y(Double(usual[keyPath: lower]))))
            }
            path.closeSubpath()
            return path
        }

        /// Lines between counted days that follow each other.
        var solid: Path {
            var path = Path()
            var previous: Int?
            for (i, point) in figures.points.enumerated() {
                guard let items = point.items else {
                    previous = nil
                    continue
                }
                let p = CGPoint(x: x(i), y: y(Double(items)))
                if previous != nil { path.addLine(to: p) } else { path.move(to: p) }
                previous = i
            }
            return path
        }

        /// Dotted threads across gaps, so the eye can follow the line without reading a value into the gap.
        var threads: Path {
            var path = Path()
            var last: (Int, Int)?
            for (i, point) in figures.points.enumerated() {
                guard let items = point.items else { continue }
                if let (j, previous) = last, i - j > 1 {
                    path.move(to: CGPoint(x: x(j), y: y(Double(previous))))
                    path.addLine(to: CGPoint(x: x(i), y: y(Double(items))))
                }
                last = (i, items)
            }
            return path
        }
    }
}
