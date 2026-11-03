// The calendar of closed days (docs/SPEC.md section 5.4, Consistency): every workday of the range by week, a sealed day
// filled, a day that closed unsealed outlined (the gap), a day still inside its grace window dashed, a day off bare.
// Each state has its own form, so none relies on colour (section 6.7).
import CadenceCore
import SwiftUI

public struct ConsistencyFigures: ChartFigures {
    public enum State: Sendable, Equatable {
        /// Sealed within its grace window.
        case sealed
        /// Its grace window closed without a seal: the gap.
        case notSealed
        /// Today, or a past workday still inside its grace window. Not counted yet.
        case open
        /// Leave, a holiday or a weekend: never counted.
        case off(DayKind)
        /// A workday before the ledger began: nothing was recorded.
        case beforeLedger
    }

    public struct Day: Sendable, Equatable {
        public var date: LocalDate
        public var state: State

        public init(date: LocalDate, state: State) {
            self.date = date
            self.state = state
        }
    }

    public var days: [Day]
    let dates: ChartDates

    public init(days: [Day], locale: Locale) {
        self.days = days
        self.dates = ChartDates(locale: locale)
    }

    public static func == (a: ConsistencyFigures, b: ConsistencyFigures) -> Bool {
        a.days == b.days && a.dates.locale == b.dates.locale
    }

    public var sealed: Int { days.filter { $0.state == .sealed }.count }
    public var notSealed: [LocalDate] { days.filter { $0.state == .notSealed }.map(\.date) }
    /// Workdays whose outcome is final: sealed or not.
    public var counted: Int { sealed + notSealed.count }

    /// The weekday columns: Monday to Friday, and a weekend day only when one in the range is a workday.
    public var columns: [Weekday] {
        let weekend: [Weekday] = [.sat, .sun].filter { weekday in
            days.contains { $0.date.weekday == weekday && Self.isWorkday($0.state) }
        }
        return [.mon, .tue, .wed, .thu, .fri] + weekend
    }

    /// One row per week the range touches, Monday first. A day outside the range or in no column is nil.
    public var weeks: [[Day?]] {
        guard let first = days.first?.date, let last = days.last?.date else { return [] }
        let byDate = Dictionary(days.map { ($0.date, $0) }, uniquingKeysWith: { a, _ in a })
        let monday = first.adding(days: -(Weekday.allCases.firstIndex(of: first.weekday) ?? 0))
        let count = monday.days(until: last) / 7 + 1
        return (0..<count).map { week in
            columns.map { weekday in
                byDate[monday.adding(days: 7 * week + (Weekday.allCases.firstIndex(of: weekday) ?? 0))]
            }
        }
    }

    /// Days shown in the calendar: every day but the weekends that are not workdays.
    var shown: [Day] {
        days.filter { day in
            if case .off(.weekend) = day.state { return false }
            return true
        }
    }

    static func isWorkday(_ state: State) -> Bool {
        if case .off = state { return false }
        return true
    }

    public var summary: String {
        guard let first = days.first?.date, let last = days.last?.date else { return String(localized: "No days in this range.") }
        var text = String(localized: "\(sealed) of \(ChartText.count(counted, String(localized: "workday"))) closed, \(dates.range(first, last)).")
        let gaps = notSealed
        if !gaps.isEmpty {
            text += String(localized: " Not sealed: ") + ChartText.list(gaps.map(dates.short)) + "."
        }
        let open = days.filter { $0.state == .open }.count
        if open > 0 { text += String(localized: " \(ChartText.count(open, String(localized: "day"))) still open.") }
        return text
    }

    public var table: ChartTable {
        ChartTable(columns: [String(localized: "Day"), String(localized: "State")], rows: shown.map { [dates.weekdayShort($0.date), Self.word($0.state)] })
    }

    static func word(_ state: State) -> String {
        switch state {
        case .sealed: String(localized: "Sealed")
        case .notSealed: String(localized: "Not sealed")
        case .open: String(localized: "Still open")
        case .off(let kind): kind == .holiday ? String(localized: "Holiday") : kind == .weekend ? String(localized: "Weekend") : String(localized: "Leave")
        case .beforeLedger: String(localized: "Before the log began")
        }
    }
}

public struct ConsistencyCalendar: View {
    let figures: ConsistencyFigures

    public init(_ figures: ConsistencyFigures) {
        self.figures = figures
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: CadenceSpace.s8) {
            Grid(horizontalSpacing: ChartMetrics.cellGap, verticalSpacing: ChartMetrics.cellGap) {
                GridRow {
                    ForEach(figures.columns, id: \.self) { weekday in
                        Text(figures.dates.weekdayShortName(weekday))
                            .cadenceType(ChartType.axis)
                            .foregroundStyle(CadenceColor.ink3.color)
                            .frame(maxWidth: .infinity)
                    }
                }
                ForEach(Array(figures.weeks.enumerated()), id: \.offset) { _, week in
                    GridRow {
                        ForEach(Array(week.enumerated()), id: \.offset) { _, day in
                            cell(day)
                        }
                    }
                }
            }
            ChartHint(text: legend)
        }
        .chartAccessibility(figures.summary)
    }

    /// Names only the forms the calendar shows.
    private var legend: String {
        var parts = [String(localized: "Filled: sealed.")]
        if !figures.notSealed.isEmpty { parts.append(String(localized: "Outlined: not sealed.")) }
        if figures.days.contains(where: { $0.state == .open }) { parts.append(String(localized: "Dashed: still open.")) }
        return parts.joined(separator: " ")
    }

    @ViewBuilder private func cell(_ day: ConsistencyFigures.Day?) -> some View {
        let shape = RoundedRectangle(cornerRadius: CadenceRadius.small, style: .continuous)
        if let day {
            Text(figures.dates.dayNumber(day.date))
                .cadenceType(ChartType.day)
                .foregroundStyle(textColor(day.state))
                .frame(maxWidth: .infinity)
                .frame(height: ChartMetrics.cell)
                .background {
                    switch day.state {
                    case .sealed: shape.fill(CadenceColor.brand.color)
                    case .notSealed: shape.strokeBorder(CadenceColor.ink.color, lineWidth: ChartMetrics.cellRing)
                    case .open:
                        shape.strokeBorder(
                            CadenceColor.ink3.color, style: StrokeStyle(lineWidth: ChartMetrics.cellRing, dash: [ChartMetrics.cellDash]))
                    case .off, .beforeLedger: Color.clear
                    }
                }
        } else {
            Color.clear.frame(height: ChartMetrics.cell)
        }
    }

    private func textColor(_ state: ConsistencyFigures.State) -> Color {
        switch state {
        case .sealed: CadenceColor.onBrand.color
        case .notSealed, .open: CadenceColor.ink.color
        case .off, .beforeLedger: CadenceColor.ink3.color
        }
    }
}
