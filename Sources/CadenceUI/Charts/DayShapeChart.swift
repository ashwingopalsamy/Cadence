// Day shape (docs/SPEC.md section 5.4): the usual first and last activity for each weekday, from workdays only. Each row
// spans the median start to the median end on one shared clock axis, with both times printed beside it. A weekday with
// no reading has no bar and prints "-": no day is not a day at 00:00.
import CadenceCore
import SwiftUI

public struct DayShapeFigures: ChartFigures {
    public struct Row: Sendable, Equatable {
        public var weekday: Weekday
        /// "09:40", or nil when unknown.
        public var start: String?
        public var end: String?
        /// The days the start was read from.
        public var days: Int?
    }

    public var rows: [Row]
    let dates: ChartDates

    public init(shape: [WeekdayShape], locale: Locale) {
        rows = shape.map { row in
            Row(weekday: row.weekday, start: row.firstActivity?.median, end: row.lastActivity?.median, days: row.firstActivity?.days)
        }
        dates = ChartDates(locale: locale)
    }

    public static func == (a: DayShapeFigures, b: DayShapeFigures) -> Bool { a.rows == b.rows && a.dates.locale == b.dates.locale }

    public var isEmpty: Bool { rows.allSatisfy { $0.start == nil && $0.end == nil } }

    /// Minutes after midnight of "HH:MM".
    static func minutes(_ text: String?) -> Int? {
        guard let parts = text?.split(separator: ":").compactMap({ Int($0) }), parts.count == 2 else { return nil }
        return parts[0] * 60 + parts[1]
    }

    /// The axis: whole hours around every known time.
    public var axis: ClosedRange<Int> {
        let known = rows.flatMap { [Self.minutes($0.start), Self.minutes($0.end)] }.compactMap { $0 }
        guard let low = known.min(), let high = known.max() else { return 9 * 60...18 * 60 }
        let start = low / 60 * 60
        let end = max(start + 60, (high + 59) / 60 * 60)
        return start...end
    }

    /// Three ticks: the axis ends and its middle hour.
    public var ticks: [String] {
        let a = axis
        let middle = (a.lowerBound + a.upperBound) / 2 / 60 * 60
        return [a.lowerBound, middle, a.upperBound].map { String(format: "%02d:%02d", $0 / 60, $0 % 60) }
    }

    static func span(_ row: Row) -> String { String(localized: "\(row.start ?? ChartText.unknown) to \(row.end ?? ChartText.unknown)") }

    public var summary: String {
        guard !isEmpty else { return String(localized: "No usual start or end yet.") }
        return String(localized: "Usual first and last activity on workdays: ")
            + rows.map { "\(dates.weekdayName($0.weekday)) \($0.start == nil && $0.end == nil ? String(localized: "unknown") : Self.span($0))" }
            .joined(separator: ", ") + "."
    }

    public var table: ChartTable {
        ChartTable(
            columns: [String(localized: "Day"), String(localized: "Usual start"), String(localized: "Usual end"), String(localized: "Days")],
            rows: rows.map { row in
                [dates.weekdayShortName(row.weekday), row.start ?? ChartText.unknown, row.end ?? ChartText.unknown, ChartText.value(row.days)]
            })
    }
}

public struct DayShapeChart: View {
    let figures: DayShapeFigures

    public init(_ figures: DayShapeFigures) {
        self.figures = figures
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: CadenceSpace.s6) {
            ForEach(figures.rows, id: \.weekday) { row in
                HStack(spacing: CadenceSpace.s8) {
                    Text(figures.dates.weekdayShortName(row.weekday))
                        .cadenceType(ChartType.axis)
                        .foregroundStyle(CadenceColor.ink3.color)
                        .frame(width: ChartMetrics.shapeLabel, alignment: .leading)
                    track(row)
                    Text(DayShapeFigures.span(row))
                        .cadenceType(CadenceType.figure)
                        .foregroundStyle(row.start == nil && row.end == nil ? CadenceColor.ink3.color : CadenceColor.ink2.color)
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            HStack(spacing: CadenceSpace.s8) {
                Color.clear.frame(width: ChartMetrics.shapeLabel, height: 0)
                HStack {
                    ForEach(Array(figures.ticks.enumerated()), id: \.offset) { index, tick in
                        if index > 0 { Spacer(minLength: 0) }
                        Text(tick)
                    }
                }
                .frame(maxWidth: .infinity)
                // Holds the width of the times column, so the ticks sit under the tracks.
                Text(DayShapeFigures.span(DayShapeFigures.Row(weekday: .mon, start: "00:00", end: "00:00", days: nil)))
                    .fixedSize()
                    .hidden()
            }
            .cadenceType(CadenceType.figure)
            .foregroundStyle(CadenceColor.ink3.color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .chartAccessibility(figures.summary)
    }

    private func track(_ row: DayShapeFigures.Row) -> some View {
        let axis = figures.axis
        let length = CGFloat(max(1, axis.upperBound - axis.lowerBound))
        let shape = RoundedRectangle(cornerRadius: CadenceRadius.small, style: .continuous)
        return GeometryReader { proxy in
            if let start = DayShapeFigures.minutes(row.start), let end = DayShapeFigures.minutes(row.end), end >= start {
                shape.fill(CadenceColor.brand.color)
                    .frame(width: max(ChartMetrics.shapeTrack, proxy.size.width * CGFloat(end - start) / length))
                    .offset(x: proxy.size.width * CGFloat(start - axis.lowerBound) / length)
            }
        }
        .frame(height: ChartMetrics.shapeTrack)
        .frame(maxWidth: .infinity)
        .background(shape.fill(CadenceColor.track.color))
    }
}
