// Week bars on one shared baseline (docs/SPEC.md section 5.4): Plan weeks prints the share of plan on each bar, and
// Reviews prints the count. Partial weeks are hatched. A week whose figure is unknown has no bar and prints "-".
import CadenceCore
import SwiftUI

public struct WeekBarsFigures: ChartFigures {
    public struct Bar: Sendable, Equatable {
        /// The Monday that starts the week.
        public var monday: LocalDate
        /// "W43", under the bar.
        public var label: String
        /// "Week 43", in the table and the sentence.
        public var name: String
        /// The height, nil when unknown.
        public var value: Int?
        /// What is printed over the bar: "86%", "12" or "-".
        public var text: String
        /// A second figure for the table, such as "14 of 16".
        public var detail: String?
        /// Hatched: the range cut the week short, it holds today, or it began before the ledger.
        public var partial: Bool
    }

    /// "Share of plan done by week".
    public var title: String
    /// The table's value column: "Share" or "Reviews".
    public var valueColumn: String
    /// The table's detail column, when the bars carry one: "Done".
    public var detailColumn: String?
    public var bars: [Bar]
    /// The value that fills the plot: 100 for shares, the largest count otherwise, so every bar shares one baseline.
    public var scale: Int
    public var hue: ChartHue

    public var hasPartial: Bool { bars.contains(where: \.partial) }

    public var summary: String {
        let parts = bars.map { bar in
            "\(bar.name), \(bar.value == nil ? String(localized: "unknown") : bar.text)\(bar.partial ? String(localized: ", partial") : "")"
        }
        return "\(title). " + parts.joined(separator: "; ") + "."
    }

    public var table: ChartTable {
        ChartTable(
            columns: [String(localized: "Week")] + (detailColumn.map { [$0] } ?? []) + [valueColumn],
            rows: bars.map { bar in
                [bar.partial ? String(localized: "\(bar.name), partial") : bar.name] + (detailColumn == nil ? [] : [bar.detail ?? ChartText.unknown])
                    + [bar.text]
            })
    }

    /// Plan weeks: planned tasks done over planned, as a share, per week.
    public static func plan(_ weeks: [WeekPoint]) -> WeekBarsFigures {
        WeekBarsFigures(
            title: String(localized: "Share of plan done by week"), valueColumn: String(localized: "Share"), detailColumn: String(localized: "Done"),
            bars: weeks.map { week in
                let percent = ChartText.percent(week.planDone, of: week.planTotal)
                let detail = week.planDone.flatMap { done in week.planTotal.map { String(localized: "\(done) of \($0)") } }
                return bar(week, value: percent, text: percent.map { "\($0)%" } ?? ChartText.unknown, detail: detail)
            },
            scale: 100, hue: .brand)
    }

    /// Reviews given per week.
    public static func reviews(_ weeks: [WeekPoint]) -> WeekBarsFigures {
        WeekBarsFigures(
            title: String(localized: "Reviews given by week"), valueColumn: String(localized: "Reviews"), detailColumn: nil,
            bars: weeks.map { bar($0, value: $0.reviews, text: ChartText.value($0.reviews), detail: nil) },
            scale: max(1, weeks.compactMap(\.reviews).max() ?? 1), hue: .family(.review))
    }

    private static func bar(_ week: WeekPoint, value: Int?, text: String, detail: String?) -> Bar {
        let number = ChartDates.isoWeek(week.monday)
        return Bar(monday: week.monday, label: String(localized: "W\(number)"), name: String(localized: "Week \(number)"), value: value, text: text, detail: detail, partial: week.partial)
    }
}

/// Bars on a shared baseline, the value printed over each, the week under it.
public struct WeekBars: View {
    let figures: WeekBarsFigures

    public init(_ figures: WeekBarsFigures) {
        self.figures = figures
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .bottom, spacing: ChartMetrics.barGap) {
                ForEach(figures.bars, id: \.monday) { bar in
                    column(bar)
                }
            }
            .frame(height: ChartMetrics.plot + ChartType.value.lineHeight + CadenceSpace.s4, alignment: .bottom)
            Rectangle().fill(CadenceColor.line.color).frame(height: CadenceStroke.hair)
            HStack(spacing: ChartMetrics.barGap) {
                ForEach(figures.bars, id: \.monday) { bar in
                    Text(bar.label)
                        .cadenceType(ChartType.axis)
                        .foregroundStyle(CadenceColor.ink3.color)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.top, CadenceSpace.s2)
            if figures.hasPartial {
                ChartHint(text: String(localized: "Hatched weeks are partial.")).padding(.top, CadenceSpace.s4)
            }
        }
        .chartAccessibility(figures.summary)
    }

    private func column(_ bar: WeekBarsFigures.Bar) -> some View {
        VStack(spacing: CadenceSpace.s4) {
            Text(bar.text)
                .cadenceType(ChartType.value)
                .foregroundStyle(bar.value == nil ? CadenceColor.ink3.color : CadenceColor.ink.color)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            if let height = height(bar) {
                BarFill(
                    shape: UnevenRoundedRectangle(
                        topLeadingRadius: ChartMetrics.barRadius, topTrailingRadius: ChartMetrics.barRadius, style: .continuous),
                    color: figures.hue.token.color, hatched: bar.partial
                )
                .frame(height: height)
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// Nil when there is nothing to draw: unknown, or a known zero, which prints "0" on the baseline.
    private func height(_ bar: WeekBarsFigures.Bar) -> CGFloat? {
        guard let value = bar.value, value > 0 else { return nil }
        let share = CGFloat(min(value, figures.scale)) / CGFloat(max(1, figures.scale))
        return max(ChartMetrics.minBar, share * ChartMetrics.plot)
    }
}

/// Plan weeks: the share of plan done on each bar, partial weeks hatched.
public struct PlanWeeks: View {
    let weeks: [WeekPoint]

    public init(_ weeks: [WeekPoint]) {
        self.weeks = weeks
    }

    public var body: some View { WeekBars(.plan(weeks)) }
}
