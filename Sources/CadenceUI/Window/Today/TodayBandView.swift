// The rhythm band in the hero (docs/SPEC.md sections 5.1 and 6.7): your own usual range day by day in the world's two
// band tones, the line of items logged per counted workday, hollow dots where a day fell outside its range, and today
// against usual by now. It reads as one sentence to VoiceOver and has a table twin.
import CadenceCore
import SwiftUI

struct BandBlock: View {
    var band: TodayBand
    var world: ColorWorld
    var width: TodayWidth
    var side: CGFloat
    var locale: Locale
    @State private var showsTable = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: CadenceSpace.s8) {
                Text("Items logged per workday")
                    .cadenceType(CadenceType.label)
                    .fontWeight(.bold)
                    .lineLimit(1)
                Spacer(minLength: 0)
                TwinToggle(showsTable: $showsTable, ink: world.ink.color, ground: world.ink.color.opacity(TodayGeometry.onWorldTint))
            }
            .frame(height: CadenceSize.chip)
            .padding(.horizontal, side)
            .padding(.top, TodayGeometry.bandHeaderGap)
            .padding(.bottom, CadenceSpace.s4)
            if showsTable {
                BandTable(rows: band.rows(locale: locale))
                    .frame(height: TodayGeometry.bandHeight + TodayGeometry.bandLegend)
                    .padding(.horizontal, side)
            } else {
                BandChart(band: band, world: world)
                    .frame(height: TodayGeometry.bandHeight)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(band.voice)
                    .accessibilityAddTraits(.isImage)
                legend
            }
        }
    }

    private var legend: some View {
        HStack(alignment: .top, spacing: CadenceSpace.s8) {
            Text(band.history.first.map { TodayFormat.shortDate($0.date, locale: locale) } ?? "")
            Spacer(minLength: 0)
            if width == .wide {
                Text(band.legend).lineLimit(1)
                Spacer(minLength: 0)
            }
            Text(TodayFormat.shortDate(band.date, locale: locale))
        }
        .cadenceType(CadenceType.comparison)
        .fontWeight(.semibold)
        .padding(.horizontal, side)
        .padding(.top, CadenceSpace.s4)
        .padding(.bottom, CadenceSpace.s8)
        .frame(minHeight: TodayGeometry.bandLegend, alignment: .top)
        .accessibilityHidden(true)
    }
}

/// The drawing. The ribbons and the line stretch with the width; the dots and the today mark keep their size.
struct BandChart: View {
    var band: TodayBand
    var world: ColorWorld
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        GeometryReader { proxy in
            let w = proxy.size.width
            let h = proxy.size.height
            let scale = Scale(band: band, width: w, height: h)
            ZStack(alignment: .topLeading) {
                Canvas { context, _ in draw(in: &context, scale) }
                ForEach(TodayGeometry.bandTicks.filter { Double($0) < scale.top }, id: \.self) { tick in
                    Text("\(tick)")
                        .cadenceType(CadenceType.label)
                        .opacity(TodayGeometry.bandTickOpacity)
                        .position(x: TodayGeometry.bandTickInset + CadenceSpace.s4, y: scale.y(Double(tick)))
                }
                todayLabel(scale)
            }
        }
    }

    /// Where values land: the prototype's scale, with a floor low enough for a quiet day.
    struct Scale {
        var count: Int
        var width: CGFloat
        var height: CGFloat
        var top: Double
        var bottom: Double

        init(band: TodayBand, width: CGFloat, height: CGFloat) {
            let values = band.values + [band.usual.low, band.usual.high]
            count = band.history.count + 1
            self.width = width
            self.height = height
            top = max(TodayGeometry.bandCeiling, Double(values.max() ?? 0)) + TodayGeometry.bandHeadroom
            bottom = min(TodayGeometry.bandFloor, Double(values.min() ?? 0) - TodayGeometry.bandHeadroom)
        }

        func x(_ i: Int) -> CGFloat { (CGFloat(i) + 0.5) / CGFloat(count) * width }
        /// The ribbon runs to both edges.
        func edgeX(_ i: Int) -> CGFloat { i == 0 ? 0 : i == count - 1 ? width : x(i) }
        func y(_ n: Double) -> CGFloat {
            let usable = height - TodayGeometry.bandInset - TodayGeometry.bandTopInset
            return height - TodayGeometry.bandInset - CGFloat((n - bottom) / (top - bottom)) * usable
        }
    }

    private func draw(in context: inout GraphicsContext, _ s: Scale) {
        let ink = world.ink.color
        // The usual range as it stood on each date, today's last: high to median in `a`, median to low in `b`.
        let ranges: [UsualRange?] = band.history.map(\.usual) + [band.usual]
        let start = ranges.firstIndex { $0 != nil } ?? ranges.count
        if start < ranges.count {
            let run = Array(start..<ranges.count)
            func ribbon(_ upper: (UsualRange) -> Int, _ lower: (UsualRange) -> Int) -> Path {
                var path = Path()
                for (k, i) in run.enumerated() {
                    let point = CGPoint(x: s.edgeX(i), y: s.y(Double(upper(ranges[i]!))))
                    k == 0 ? path.move(to: point) : path.addLine(to: point)
                }
                for i in run.reversed() { path.addLine(to: CGPoint(x: s.edgeX(i), y: s.y(Double(lower(ranges[i]!))))) }
                path.closeSubpath()
                return path
            }
            context.fill(ribbon(\.high, \.median), with: .color(world.a.color))
            context.fill(ribbon(\.median, \.low), with: .color(world.b.color))
            // Increase Contrast: the band gains an edge (section 6.7), as the rhythm band chart draws it.
            if contrast == .increased {
                context.stroke(ribbon(\.high, \.low), with: .color(ink.opacity(ChartMetrics.edgeOpacity)), lineWidth: ChartMetrics.edge)
            }
        }

        // The line through every counted day, today included when something is logged.
        let values = band.values
        if values.count > 1 {
            var line = Path()
            for (i, n) in values.enumerated() {
                let point = CGPoint(x: s.x(i), y: s.y(Double(n)))
                i == 0 ? line.move(to: point) : line.addLine(to: point)
            }
            context.stroke(line, with: .color(ink), style: StrokeStyle(lineWidth: TodayGeometry.bandLine, lineJoin: .round))
        }

        // Filled inside the range of its date, hollow outside.
        for (i, point) in band.history.enumerated() {
            let d = TodayGeometry.dot
            let rect = CGRect(x: s.x(i) - d / 2, y: s.y(Double(point.items)) - d / 2, width: d, height: d)
            if point.inside {
                context.fill(Path(ellipseIn: rect), with: .color(ink))
            } else {
                context.fill(Path(ellipseIn: rect), with: .color(world.bg.color))
                context.stroke(Path(ellipseIn: rect.insetBy(dx: TodayGeometry.dotStroke / 2, dy: TodayGeometry.dotStroke / 2)), with: .color(ink), lineWidth: TodayGeometry.dotStroke)
            }
        }

        let last = s.x(s.count - 1)
        // Usual by now, as a bracket at today. A stale source suppresses the comparison.
        if let byNow = band.byNow, !band.stale, band.today != nil {
            let top = s.y(Double(byNow.high))
            let height = max(TodayGeometry.bracketWidth, s.y(Double(byNow.low)) - top)
            let rect = CGRect(x: last - TodayGeometry.bracketWidth / 2, y: top, width: TodayGeometry.bracketWidth, height: height)
            context.fill(
                Path(roundedRect: rect, cornerRadius: CadenceSpace.s4), with: .color(ink.opacity(TodayGeometry.bracketOpacity)))
        }

        if let today = band.today {
            let d = TodayGeometry.todayMark
            let rect = CGRect(x: last - d / 2, y: s.y(Double(today)) - d / 2, width: d, height: d)
            if band.stale {
                let stroke = TodayGeometry.dotStroke
                context.stroke(Path(ellipseIn: rect.insetBy(dx: stroke / 2, dy: stroke / 2)), with: .color(ink), style: StrokeStyle(lineWidth: stroke, dash: TodayGeometry.dash))
            } else {
                let stroke = TodayGeometry.todayStroke
                context.fill(Path(ellipseIn: rect), with: .color(TodayGeometry.todayFill))
                context.stroke(Path(ellipseIn: rect.insetBy(dx: stroke / 2, dy: stroke / 2)), with: .color(ink), lineWidth: stroke)
            }
        } else {
            // Nothing logged yet: a dashed place in the middle of the usual day, never a zero.
            let d = TodayGeometry.pendingMark
            let middle = Double(band.usual.low + band.usual.high) / 2
            let rect = CGRect(x: last - d / 2, y: s.y(middle) - d / 2, width: d, height: d)
            let stroke = TodayGeometry.pendingStroke
            context.stroke(Path(ellipseIn: rect.insetBy(dx: stroke / 2, dy: stroke / 2)), with: .color(ink), style: StrokeStyle(lineWidth: stroke, dash: TodayGeometry.dash))
        }
    }

    private func todayLabel(_ s: Scale) -> some View {
        let middle = Double(band.usual.low + band.usual.high) / 2
        let y = s.y(band.today.map(Double.init) ?? middle)
        return HStack {
            Spacer(minLength: 0)
            Text(band.today.map { band.name == nil ? String(localized: "Today, \($0)") : "\(band.lastName), \($0)" } ?? band.lastName)
                .cadenceType(CadenceType.comparison)
                .fontWeight(.heavy)
                .fontDesign(.rounded)
                .padding(.horizontal, TodayGeometry.todayLabelPad)
                .background(RoundedRectangle(cornerRadius: CadenceSpace.s4).fill(world.bg.color))
        }
        .padding(.trailing, TodayGeometry.todayLabelTrailing)
        .offset(y: max(CadenceSpace.s2, y - TodayGeometry.todayLabelRise))
    }
}

/// The band's table twin: one column per counted workday, today last.
struct BandTable: View {
    var rows: [[String]]

    var body: some View {
        ScrollView(.horizontal) {
            Grid(alignment: .leading, horizontalSpacing: CadenceSpace.s12, verticalSpacing: CadenceSpace.s8) {
                GridRow {
                    Text("Day")
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in Text(row[0]) }
                }
                .cadenceType(CadenceType.label)
                GridRow {
                    Text("Items")
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in Text(row[1]) }
                }
                .cadenceType(CadenceType.body)
                GridRow {
                    Text("Usual")
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in Text(row[2]) }
                }
                .cadenceType(CadenceType.comparison)
            }
            .padding(.vertical, CadenceSpace.s8)
        }
        .accessibilityLabel("Items logged per workday, as a table")
    }
}
