import CadenceCore
import Foundation
import Testing

@testable import CadenceCore
@testable import CadenceUI

/// The charts of docs/SPEC.md section 5.4: each table twin carries the figures the picture draws, each reads to
/// VoiceOver as one sentence, and an unknown figure is never drawn or printed as zero.
@Suite struct ChartTests {
    static let gb = Locale(identifier: "en_GB")

    static func day(_ text: String) -> LocalDate { LocalDate(text)! }

    static func week(_ monday: String, done: Int?, of total: Int?, reviews: Int?, partial: Bool = false) -> WeekPoint {
        WeekPoint(monday: day(monday), planDone: done, planTotal: total, mergedPRs: nil, reviews: reviews, partial: partial)
    }

    static let weeks = [
        week("2026-09-28", done: 6, of: 7, reviews: 5, partial: true),
        week("2026-10-05", done: 14, of: 16, reviews: 12),
        week("2026-10-12", done: nil, of: nil, reviews: nil),
        week("2026-10-19", done: 0, of: 0, reviews: 0),
        week("2026-10-26", done: 11, of: 15, reviews: 11, partial: true),
    ]

    // MARK: week bars

    @Test func planWeeksPrintsTheShareOfEachWeekAndTheTableCarriesTheSameFigures() {
        let figures = WeekBarsFigures.plan(Self.weeks)
        #expect(figures.bars.map(\.label) == ["W40", "W41", "W42", "W43", "W44"])
        #expect(figures.bars.map(\.text) == ["86%", "88%", "-", "-", "73%"])
        #expect(figures.bars.map(\.value) == [86, 88, nil, nil, 73])
        #expect(figures.scale == 100)
        #expect(figures.table.columns == ["Week", "Done", "Share"])
        #expect(
            figures.table.rows == [
                ["Week 40, partial", "6 of 7", "86%"], ["Week 41", "14 of 16", "88%"], ["Week 42", "-", "-"],
                ["Week 43", "0 of 0", "-"], ["Week 44, partial", "11 of 15", "73%"],
            ])
        // Every printed value is in the table.
        for (bar, row) in zip(figures.bars, figures.table.rows) { #expect(row.last == bar.text) }
        #expect(
            figures.summary
                == "Share of plan done by week. Week 40, 86%, partial; Week 41, 88%; Week 42, unknown; Week 43, unknown; Week 44, 73%, partial.")
    }

    @Test func reviewBarsShareOneBaselineAndAnUnknownWeekIsNotZero() {
        let figures = WeekBarsFigures.reviews(Self.weeks)
        #expect(figures.bars.map(\.text) == ["5", "12", "-", "0", "11"])
        #expect(figures.bars.map(\.value) == [5, 12, nil, 0, 11])
        #expect(figures.scale == 12)
        #expect(figures.hasPartial)
        #expect(figures.table.rows.map(\.last) == ["5", "12", "-", "0", "11"])
        #expect(figures.summary.contains("Week 42, unknown"))
        #expect(figures.summary.contains("Week 43, 0"))
    }

    // MARK: consistency

    static func calendar() -> ConsistencyFigures {
        // Thu 1 Oct to Wed 7 Oct: a gap on the 1st, a holiday on the 2nd, a weekend, then sealed days and today open.
        ConsistencyFigures(
            days: [
                .init(date: day("2026-10-01"), state: .notSealed), .init(date: day("2026-10-02"), state: .off(.holiday)),
                .init(date: day("2026-10-03"), state: .off(.weekend)), .init(date: day("2026-10-04"), state: .off(.weekend)),
                .init(date: day("2026-10-05"), state: .sealed), .init(date: day("2026-10-06"), state: .sealed),
                .init(date: day("2026-10-07"), state: .open),
            ], locale: gb)
    }

    @Test func theCalendarLaysWorkdaysOutByWeekAndOutlinesTheGap() {
        let figures = Self.calendar()
        #expect(figures.columns == [.mon, .tue, .wed, .thu, .fri])
        #expect(figures.weeks.count == 2)
        #expect(figures.weeks[0].map { $0?.date.day } == [nil, nil, nil, 1, 2])
        #expect(figures.weeks[1].map { $0?.date.day } == [5, 6, 7, nil, nil])
        #expect(figures.sealed == 2)
        #expect(figures.counted == 3)
        #expect(figures.notSealed == [Self.day("2026-10-01")])
        #expect(figures.summary == "2 of 3 workdays closed, 1 to 7 Oct. Not sealed: 1 Oct. 1 day still open.")
        #expect(
            figures.table.rows == [
                ["Thu 1 Oct", "Not sealed"], ["Fri 2 Oct", "Holiday"], ["Mon 5 Oct", "Sealed"], ["Tue 6 Oct", "Sealed"],
                ["Wed 7 Oct", "Still open"],
            ])
    }

    @Test func aWorkdayOnAWeekendAddsItsColumn() {
        let figures = ConsistencyFigures(
            days: [.init(date: Self.day("2026-10-09"), state: .sealed), .init(date: Self.day("2026-10-10"), state: .sealed)], locale: Self.gb)
        #expect(figures.columns == [.mon, .tue, .wed, .thu, .fri, .sat])
        #expect(figures.table.rows.count == 2)
    }

    // MARK: split, strata, slips, tiles

    @Test func theSplitBarLeavesOutEmptyPartsAndUnknownSplits() {
        #expect(SplitFigures(merged: nil, assigned: 1, selfStarted: 1) == nil)
        #expect(SplitFigures(merged: 4, assigned: nil, selfStarted: 1) == nil)
        let figures = SplitFigures(merged: 14, assigned: 11, selfStarted: 3)!
        #expect(figures.noTicket == 0)
        #expect(figures.parts.map(\.label) == ["Assigned", "Self-started"])
        #expect(figures.table.rows == [["Assigned", "11"], ["Self-started", "3"], ["No ticket", "0"]])
        #expect(figures.summary == "14 PRs merged: 11 assigned, 3 self-started, 0 with no ticket.")
        #expect(SplitFigures(merged: 0, assigned: 0, selfStarted: 0)?.summary == "No PRs merged.")
    }

    @Test func strataStackOnlyWhatWasLoggedAndThicknessFollowsTheCount() {
        #expect(StrataFigures(kindCounts: nil) == nil)
        let figures = StrataFigures(kindCounts: ["meeting.led": 5, "mentoring": 3, "incident.handled": 1, "pr.merged": 9])!
        #expect(figures.layers.map(\.label) == ["Led meetings", "Mentored", "Handled incidents"])
        #expect(figures.total == 9)
        #expect(figures.table.rows == [["Led meetings", "5"], ["Mentored", "3"], ["Handled incidents", "1"]])
        #expect(figures.summary == "9 beyond the plan: 5 led meetings, 3 mentored and 1 handled incidents.")
        let thickness = figures.layers.map { StrataFigures.thickness($0.count, layers: figures.layers) }
        #expect(thickness[0] > thickness[1] && thickness[1] > thickness[2])
        // A very busy range still fits its limit, and thicker still means more.
        let busy = StrataFigures(kindCounts: ["meeting.led": 80, "mentoring": 40])!
        let total = busy.layers.map { StrataFigures.thickness($0.count, layers: busy.layers) }.reduce(0, +)
        #expect(total <= ChartMetrics.strataMax + 0.001)
        #expect(StrataFigures(kindCounts: [:])?.summary == "Nothing beyond the plan was logged.")
    }

    /// The kinds the strata stack are the kinds the findings engine calls beyond the plan.
    @Test func strataKindsAreTheFindingsKinds() {
        #expect(Set(StrataFigures.kinds.map(\.0)) == Set(Findings.beyondThePlan))
    }

    @Test func slipReasonsNameOnlyTheChipsAndNeverTypedText() {
        #expect(SlipFigures(slipsByReason: nil) == nil)
        let figures = SlipFigures(slipsByReason: [
            "reprioritised": 6, "blocked": 2, "too_big": 1, "the ACME vendor was late": 2, "a second typed one": 1, "unspecified": 1,
        ])!
        #expect(figures.reasons.map(\.label) == ["Reprioritised", "For another reason", "Blocked", "No reason given", "Too big"])
        #expect(figures.reasons.map(\.count) == [6, 3, 2, 1, 1])
        #expect(figures.table.rows.flatMap { $0 }.allSatisfy { !$0.contains("ACME") && !$0.contains("typed") })
        #expect(!figures.summary.contains("ACME"))
        #expect(figures.summary == "13 slipped: 6 reprioritised, 3 for another reason, 2 blocked, 1 with no reason and 1 too big.")
        #expect(SlipFigures(slipsByReason: [:])?.summary == "None slipped.")
    }

    @Test func countTilesShowOnlyKnownCounts() {
        let figures = CountTileFigures([
            .init(value: "19", label: "Claude Code sessions", family: .ai), nil, .init(value: "2 of 4", label: "Merged PRs AI-assisted", family: .ai),
        ])
        #expect(figures.tiles.count == 2)
        #expect(figures.table.rows == [["Claude Code sessions", "19"], ["Merged PRs AI-assisted", "2 of 4"]])
        #expect(figures.summary == "Claude Code sessions: 19. Merged PRs AI-assisted: 2 of 4.")
        #expect(CountTileFigures([nil]).summary == "No counts recorded.")
    }

    // MARK: day shape

    @Test func dayShapePrintsEachWeekdayAndAnUnknownOneAsADash() {
        let spread = { (median: String, days: Int) in ClockSpread(median: median, earliest: median, latest: median, days: days) }
        let shape = [
            WeekdayShape(weekday: .mon, firstActivity: spread("09:40", 4), lastActivity: spread("17:30", 4)),
            WeekdayShape(weekday: .tue, firstActivity: spread("10:05", 4), lastActivity: spread("18:10", 4)),
            WeekdayShape(weekday: .wed, firstActivity: nil, lastActivity: nil),
            WeekdayShape(weekday: .thu, firstActivity: spread("09:55", 3), lastActivity: nil),
            WeekdayShape(weekday: .fri, firstActivity: spread("09:35", 4), lastActivity: spread("16:50", 4)),
        ]
        let figures = DayShapeFigures(shape: shape, locale: Self.gb)
        #expect(figures.axis == 9 * 60...19 * 60)
        #expect(figures.ticks == ["09:00", "14:00", "19:00"])
        #expect(
            figures.table.rows == [
                ["Mon", "09:40", "17:30", "4"], ["Tue", "10:05", "18:10", "4"], ["Wed", "-", "-", "-"], ["Thu", "09:55", "-", "3"],
                ["Fri", "09:35", "16:50", "4"],
            ])
        #expect(figures.summary.contains("Wednesday unknown"))
        #expect(figures.summary.contains("Thursday 09:55 to -"))
        #expect(!figures.summary.contains("00:00"))
        #expect(DayShapeFigures(shape: [WeekdayShape(weekday: .mon, firstActivity: nil, lastActivity: nil)], locale: Self.gb).isEmpty)
    }

    // MARK: rhythm band

    @Test func theRhythmBandKeepsGapsAsGapsAndReadsTodayAgainstUsualByNow() {
        let usual = UsualRange(low: 5, median: 7, high: 9, days: 12)
        let points = [
            RhythmPoint(date: Self.day("2026-10-23"), items: 8, usual: usual),
            RhythmPoint(date: Self.day("2026-10-24"), items: nil, usual: usual),
            RhythmPoint(date: Self.day("2026-10-25"), items: nil, usual: usual),
            RhythmPoint(date: Self.day("2026-10-26"), items: 12, usual: usual),
            RhythmPoint(date: Self.day("2026-10-27"), items: nil, usual: nil),
        ]
        let rhythm = Rhythm(
            today: 4, usual: usual, byNow: UsualRange(low: 3, median: 4, high: 5, days: 12), plan: nil,
            points: points)
        let figures = RhythmFigures(rhythm: rhythm, clock: "14:20", locale: Self.gb)
        #expect(figures.points.count == 4)
        #expect(figures.table.rows.map { $0[1] } == ["8", "Not counted", "Not counted", "12", "4"])
        #expect(figures.table.rows.last == ["Today", "4", "3 to 5 by 14:20"])
        #expect(
            figures.summary
                == "4 items logged today. A usual day is 5 to 9, and usually 3 to 5 by 14:20. 1 earlier day fell outside its usual range.")
        #expect(figures.caption == "Usual day: 5 to 9. Usual by 14:20: 3 to 5.")

        let plot = RhythmBand.Plot(figures: figures, size: CGSize(width: 500, height: 148))
        #expect(plot.bandRuns == [0...3])
        // The line breaks over the weekend and a thread joins across it.
        #expect(!plot.threads.isEmpty)

        let stale = RhythmFigures(rhythm: rhythm, clock: "14:20", stale: true, locale: Self.gb)
        #expect(stale.byNow == nil)
        #expect(stale.summary == "4 items logged today. A source is behind, so there is no comparison.")

        let nothing = RhythmFigures(rhythm: Rhythm(today: 0, usual: nil, byNow: nil, plan: nil, points: points), clock: "09:10", locale: Self.gb)
        #expect(nothing.today == nil)
        #expect(nothing.summary == "Nothing logged yet today. Still learning your usual range.")
        #expect(nothing.table.rows.last == ["Today", "-", "-"])
    }

    // MARK: layout and copy

    @Test func proportionalWidthsHoldEveryLabelAndShareTheRestByCount() {
        let widths = ProportionalRow.widths(minimums: [60, 80, 70], weights: [12, 1, 4], total: 400)
        #expect(widths[1] == 80)
        #expect(abs(widths.reduce(0, +) - 400) < 0.001)
        #expect(widths[0] > widths[2])
        #expect(widths.enumerated().allSatisfy { $0.element >= [60, 80, 70][$0.offset] })
    }

    @Test func everyChartSentenceKeepsTheCopyRules() {
        let sentences = [
            WeekBarsFigures.plan(Self.weeks).summary, WeekBarsFigures.reviews(Self.weeks).summary, Self.calendar().summary,
            SplitFigures(merged: 4, assigned: 2, selfStarted: 1)!.summary,
            StrataFigures(kindCounts: ["meeting.led": 2])!.summary, SlipFigures(slipsByReason: ["blocked": 1])!.summary,
            "Hatched weeks are partial.",
        ]
        for sentence in sentences { #expect(CopyRules.allows(sentence), "\(sentence)") }
    }

    @Test func datesFollowTheLocaleWithoutDashes() {
        let dates = ChartDates(locale: Self.gb)
        #expect(dates.range(Self.day("2026-10-26"), Self.day("2026-10-29")) == "26 to 29 Oct")
        #expect(dates.range(Self.day("2026-09-28"), Self.day("2026-10-04")) == "28 Sep to 4 Oct")
        #expect(dates.compactRange(Self.day("2026-10-01"), Self.day("2026-10-29")) == "1 - 29 Oct")
        #expect(dates.month(Self.day("2026-09-01")) == "September")
        #expect(dates.weekdayName(.mon) == "Monday")
        #expect(dates.weekdayShortName(.fri) == "Fri")
        #expect(ChartDates.isoWeek(Self.day("2026-10-19")) == 43)
    }
}
