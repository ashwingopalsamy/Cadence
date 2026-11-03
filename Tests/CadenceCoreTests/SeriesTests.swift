import Foundation
import Testing

@testable import CadenceCore

/// docs/SPEC.md section 5.4: the weekly series behind Plan weeks and Reviews week bars. The October demo seed
/// is Thu 1 Oct to Thu 29 Oct 2026 (a holiday on Fri 2 Oct, leave on Fri 23 Oct), and its clock stops on Thu 29 Oct
/// after wrap-up, so that is "today" unless a test moves it.
@Suite struct SeriesTests {
    static func date(_ text: String) -> LocalDate { LocalDate(text)! }

    /// One point as a table row, so a whole series compares in one expectation.
    struct Row: Equatable, CustomStringConvertible {
        var monday: String
        var done: Int?
        var total: Int?
        var prs: Int?
        var reviews: Int?
        var partial: Bool

        init(_ monday: String, _ done: Int?, _ total: Int?, _ prs: Int?, _ reviews: Int?, _ partial: Bool) {
            self.monday = monday
            self.done = done
            self.total = total
            self.prs = prs
            self.reviews = reviews
            self.partial = partial
        }

        init(_ point: WeekPoint) {
            self.init(point.monday.description, point.planDone, point.planTotal, point.mergedPRs, point.reviews, point.partial)
        }

        var description: String {
            func n(_ value: Int?) -> String { value.map(String.init) ?? "nil" }
            return "\(monday) plan \(n(done))/\(n(total)) prs \(n(prs)) reviews \(n(reviews)) partial \(partial)"
        }
    }

    static func series(_ journal: Journal, _ from: String, _ to: String) throws -> [Row] {
        try journal.weeklySeries(from: date(from), to: date(to)).map(Row.init)
    }

    // MARK: weeks

    @Test func aRangeStartingMidWeekClipsItsFirstWeekAndKeepsTheMonday() throws {
        let (_, journal, _) = try DemoSeedTests.seeded()
        // Wed 7 Oct to Sun 18 Oct. The week of Mon 5 Oct is read from Wed to Sun, so it holds Wed 7, Thu 8 and Fri 9:
        // 4 of 4, 4 of 4 and 3 of 4 tasks done, 1 PR on each day, and 3, 2 and 3 reviews. The week of Mon 12 Oct is whole.
        #expect(
            try Self.series(journal, "2026-10-07", "2026-10-18") == [
                Row("2026-10-05", 11, 12, 3, 8, true),
                Row("2026-10-12", 17, 19, 3, 12, false),
            ])
    }

    @Test func aSundayBelongsToTheWeekThatStartedOnTheMondayBefore() throws {
        let (_, journal, _) = try DemoSeedTests.seeded()
        // Sun 11 Oct is a weekend day with nothing recorded: the point exists, its Monday is 5 Oct and nothing is known.
        #expect(try Self.series(journal, "2026-10-11", "2026-10-11") == [Row("2026-10-05", nil, nil, nil, nil, true)])
        #expect(try Self.series(journal, "2026-10-12", "2026-10-12").map(\.monday) == ["2026-10-12"])
    }

    @Test func aRangeThatStopsBeforeTheWeekendStillClipsThatWeek() throws {
        let (_, journal, _) = try DemoSeedTests.seeded()
        // Clipped means the week read is shorter than Monday to Sunday, whether or not the missing days are workdays.
        let friday = try Self.series(journal, "2026-10-05", "2026-10-09")
        #expect(friday == [Row("2026-10-05", 16, 20, 4, 12, true)])
        #expect(try Self.series(journal, "2026-10-05", "2026-10-11") == [Row("2026-10-05", 16, 20, 4, 12, false)])
    }

    // MARK: partial weeks

    @Test func theWeekContainingTodayIsPartialUntilItIsOver() throws {
        let (_, journal, clock) = try DemoSeedTests.seeded()
        // Today is Thu 29 Oct. Mon 26 Oct to Sun 1 Nov is read whole, so only today makes it partial.
        let week = Row("2026-10-26", 14, 18, 4, 12, true)
        #expect(try Self.series(journal, "2026-10-26", "2026-11-01") == [week])

        // On Tue 3 Nov the same week is over and nothing in it changed.
        clock.set(Timestamp.parse("2026-11-03T05:00:00Z")!)
        #expect(try Self.series(journal, "2026-10-26", "2026-11-01") == [Row("2026-10-26", 14, 18, 4, 12, false)])
    }

    @Test func aWeekThatStartedBeforeTheLedgerIsPartialAndUnknownBeforeIt() throws {
        let (_, journal, _) = try DemoSeedTests.seeded()
        // The ledger began Thu 1 Oct. Mon 28 Sep is before it, so that week is partial even though the range holds all of it.
        #expect(try Self.series(journal, "2026-09-28", "2026-10-04") == [Row("2026-09-28", 3, 4, 1, 3, true)])
        // Weeks wholly before the ledger know nothing, and nothing is plotted as zero.
        #expect(
            try Self.series(journal, "2026-09-14", "2026-09-27") == [
                Row("2026-09-14", nil, nil, nil, nil, true),
                Row("2026-09-21", nil, nil, nil, nil, true),
            ])
    }

    // MARK: unknown versus zero

    @Test func zeroIsKnownAndAnEmptyWeekIsNil() throws {
        let (_, journal, clock) = try DemoSeedTests.seeded()
        // Tue 3 Nov: two planned tasks, both slipped, and one note. That week has a plan and entries, none of them done,
        // merged or reviews.
        clock.set(Timestamp.parse("2026-11-03T05:00:00Z")!)
        for title in ["Draft the capacity note", "Review the runbook"] {
            let task = try journal.planAdd(title: title, day: nil, estimateMin: nil, origin: .selfReported, actor: .cli)
            _ = try journal.planResolve(taskID: task.id, status: .slipped, reason: "blocked", note: nil, links: [], actor: .cli)
        }
        _ = try journal.log(LogRequest(text: "Wrote the capacity note"), actor: .cli, origin: .selfReported)

        // Two weeks later both weeks are over. The first has a measured zero, the second has no plan and no entries.
        clock.set(Timestamp.parse("2026-11-17T05:00:00Z")!)
        let points = try journal.weeklySeries(from: Self.date("2026-11-02"), to: Self.date("2026-11-15"))
        #expect(points.map(Row.init) == [
            Row("2026-11-02", 0, 2, 0, 0, false),
            Row("2026-11-09", nil, nil, nil, nil, false),
        ])
    }

    // MARK: the October seed

    @Test func tableOnTheOctoberSeed() throws {
        let (_, journal, _) = try DemoSeedTests.seeded()
        let table = try Self.series(journal, "2026-10-01", "2026-10-29")
        #expect(
            table == [
                // Thu 1 Oct only (Fri 2 Oct is a holiday), clipped by the range and begun before the ledger.
                Row("2026-09-28", 3, 4, 1, 3, true),
                Row("2026-10-05", 16, 20, 4, 12, false),
                Row("2026-10-12", 17, 19, 3, 12, false),
                // Fri 23 Oct is leave: it is left out, not counted as a zero.
                Row("2026-10-19", 11, 12, 2, 8, false),
                // Mon 26 to Thu 29 Oct, clipped by the range and holding today. The SPEC 12.1 week 44 figures.
                Row("2026-10-26", 14, 18, 4, 12, true),
            ])

        // The weeks add up to the month in the SPEC 12.1 proof: 61 of 73 tasks, 14 merged PRs, 47 reviews.
        #expect(table.compactMap(\.done).reduce(0, +) == 61)
        #expect(table.compactMap(\.total).reduce(0, +) == 73)
        #expect(table.compactMap(\.prs).reduce(0, +) == 14)
        #expect(table.compactMap(\.reviews).reduce(0, +) == 47)
    }

    @Test func wholeWeeksOfTheSeedAreNotPartial() throws {
        let (_, journal, _) = try DemoSeedTests.seeded()
        #expect(
            try Self.series(journal, "2026-10-05", "2026-10-25") == [
                Row("2026-10-05", 16, 20, 4, 12, false),
                Row("2026-10-12", 17, 19, 3, 12, false),
                Row("2026-10-19", 11, 12, 2, 8, false),
            ])
    }

    @Test func everyPointIsTheSummaryOfItsClippedWeek() throws {
        let (_, journal, _) = try DemoSeedTests.seeded()
        let from = Self.date("2026-10-07")
        let to = Self.date("2026-10-28")
        for point in try journal.weeklySeries(from: from, to: to) {
            let summary = try journal.summary(from: max(point.monday, from), to: min(point.monday.adding(days: 6), to))
            #expect(point.planDone == summary.planDone)
            #expect(point.planTotal == summary.planTotal)
            #expect(point.mergedPRs == summary.mergedPRs)
            #expect(point.reviews == summary.reviews)
        }
    }

    // MARK: limits

    @Test func aRangeThatStartsAfterItEndsIsRefused() throws {
        let (_, journal, _) = try DemoSeedTests.seeded()
        #expect(throws: CadenceError.self) { try journal.weeklySeries(from: Self.date("2026-10-29"), to: Self.date("2026-10-01")) }
    }

    @Test func aRangeLongerThanASummaryIsRefused() throws {
        let (_, journal, _) = try DemoSeedTests.seeded()
        let from = Self.date("2026-10-01")
        #expect(throws: CadenceError.self) { try journal.weeklySeries(from: from, to: from.adding(days: Journal.maxSummaryDays)) }
    }
}

/// docs/SPEC.md section 5.4, Day shape: the usual first and last activity by weekday, workdays only.
@Suite struct DayShapeTests {
    static func spread(_ median: String, _ earliest: String, _ latest: String, _ days: Int) -> ClockSpread {
        ClockSpread(median: median, earliest: earliest, latest: latest, days: days)
    }

    @Test func mondayToFridayOverWorkdaysOnly() throws {
        let (journal, _, _) = try ActivityFixture.make()
        let shape = try journal.dayShape(from: SeriesTests.date("2026-10-05"), to: SeriesTests.date("2026-10-25"))
        #expect(shape.map(\.weekday) == [.mon, .tue, .wed, .thu, .fri])
        #expect(
            shape == [
                WeekdayShape(
                    weekday: .mon, firstActivity: Self.spread("10:00", "09:00", "11:00", 3),
                    lastActivity: Self.spread("18:00", "17:00", "19:00", 3)),
                // Tue 6 is New York, Tue 13 is Kolkata.
                WeekdayShape(
                    weekday: .tue, firstActivity: Self.spread("09:15", "09:00", "09:30", 2),
                    lastActivity: Self.spread("17:30", "17:30", "17:30", 2)),
                // Wed 14 is leave: only Wed 7 counts.
                WeekdayShape(
                    weekday: .wed, firstActivity: Self.spread("09:00", "09:00", "09:00", 1),
                    lastActivity: Self.spread("18:00", "18:00", "18:00", 1)),
                // Thu 8 has a start and no end, and Thu 15 is a holiday.
                WeekdayShape(weekday: .thu, firstActivity: Self.spread("10:00", "10:00", "10:00", 1), lastActivity: nil),
                // Nothing on a Friday: unknown, not 00:00.
                WeekdayShape(weekday: .fri, firstActivity: nil, lastActivity: nil),
            ])
    }

    @Test func aWeekendFirstActivityDoesNotMoveAnything() throws {
        let (journal, store, _) = try ActivityFixture.make()
        let from = SeriesTests.date("2026-10-05")
        let to = SeriesTests.date("2026-10-25")
        let before = try journal.dayShape(from: from, to: to)
        // Sat 10 and Sun 11 already carry a 05:00 and a 04:30 start. Put a Monday-sized one on a Saturday and an
        // early one on a Sunday: no weekday and no median changes, and nothing is listed for the weekend.
        try ActivityFixture.mark(store, "2026-10-24", first: "03:15", last: "23:45")
        try ActivityFixture.mark(store, "2026-10-18", first: "06:00", last: "07:00")
        #expect(try journal.dayShape(from: from, to: to) == before)
        #expect(before.map(\.weekday).allSatisfy { ![.sat, .sun].contains($0) })
    }

    @Test func aDeclaredDayOffIsIgnoredAndADeclaredWorkdayOnAWeekendHasNoWeekday() throws {
        let (journal, _, _) = try ActivityFixture.make()
        // Wed 14 (leave, 06:00 to 23:00) alone: nothing.
        let leave = try journal.dayShape(from: SeriesTests.date("2026-10-14"), to: SeriesTests.date("2026-10-14"))
        #expect(leave.allSatisfy { $0.firstActivity == nil && $0.lastActivity == nil })
        // Thu 15 (holiday, 07:00 to 12:00) alone: nothing.
        let holiday = try journal.dayShape(from: SeriesTests.date("2026-10-15"), to: SeriesTests.date("2026-10-15"))
        #expect(holiday.allSatisfy { $0.firstActivity == nil && $0.lastActivity == nil })
        // Sat 17 is a workday by declaration with a 12:00 start. The summary counts it, and the shape has no Saturday to put it in.
        let saturday = try journal.dayShape(from: SeriesTests.date("2026-10-17"), to: SeriesTests.date("2026-10-17"))
        #expect(saturday.count == 5 && saturday.allSatisfy { $0.firstActivity == nil && $0.lastActivity == nil })
    }

    @Test func aDayIsReadInItsOwnZone() throws {
        let (journal, _, _) = try ActivityFixture.make()
        // Tue 6 Oct began 09:00 and ended 17:30 in New York. That is 18:30 and 03:00 the next morning in Kolkata.
        let tuesday = try journal.dayShape(from: SeriesTests.date("2026-10-06"), to: SeriesTests.date("2026-10-06"))[1]
        #expect(tuesday.weekday == .tue)
        #expect(tuesday.firstActivity == Self.spread("09:00", "09:00", "09:00", 1))
        #expect(tuesday.lastActivity == Self.spread("17:30", "17:30", "17:30", 1))
    }

    @Test func aRangeWithNoWorkdayDataIsFiveEmptyWeekdays() throws {
        let (journal, _, _) = try ActivityFixture.make()
        let shape = try journal.dayShape(from: SeriesTests.date("2026-09-14"), to: SeriesTests.date("2026-09-20"))
        #expect(shape.map(\.weekday) == [.mon, .tue, .wed, .thu, .fri])
        #expect(shape.allSatisfy { $0.firstActivity == nil && $0.lastActivity == nil })
    }

    @Test func aRangeThatStartsAfterItEndsIsRefused() throws {
        let (journal, _, _) = try ActivityFixture.make()
        #expect(throws: CadenceError.self) { try journal.dayShape(from: SeriesTests.date("2026-10-25"), to: SeriesTests.date("2026-10-05")) }
    }

    @Test func theShapeAndTheSummaryReadTheSameDays() throws {
        let (journal, _, _) = try ActivityFixture.make()
        let from = SeriesTests.date("2026-10-05")
        let to = SeriesTests.date("2026-10-25")
        let shape = try journal.dayShape(from: from, to: to)
        let summary = try journal.summary(from: from, to: to)
        // Sat 17 is a declared workday, so the summary counts its start. The shape has no Saturday, so it holds the other seven.
        #expect(shape.compactMap(\.firstActivity).map(\.days).reduce(0, +) == 7)
        #expect(summary.firstActivity?.days == 8)
    }

    // MARK: the October seed

    @Test func tableOnTheOctoberSeed() throws {
        let (_, journal, _) = try DemoSeedTests.seeded()
        let shape = try journal.dayShape(from: SeriesTests.date("2026-10-01"), to: SeriesTests.date("2026-10-29"))
        // The days that count: Mon 5, 12, 19, 26. Tue 6, 13, 20, 27. Wed 7, 14, 21, 28. Thu 1, 8, 15, 22, 29. Fri 9 and
        // 16, because Fri 2 is a holiday and Fri 23 is leave. An even count takes the mean of the middle two, to the minute.
        #expect(
            shape == [
                WeekdayShape(
                    weekday: .mon, firstActivity: Self.spread("09:37", "09:33", "10:05", 4),
                    lastActivity: Self.spread("17:38", "17:15", "18:18", 4)),
                WeekdayShape(
                    weekday: .tue, firstActivity: Self.spread("10:01", "09:36", "10:07", 4),
                    lastActivity: Self.spread("17:39", "17:20", "17:53", 4)),
                WeekdayShape(
                    weekday: .wed, firstActivity: Self.spread("10:01", "09:42", "10:11", 4),
                    lastActivity: Self.spread("17:59", "17:33", "18:14", 4)),
                WeekdayShape(
                    weekday: .thu, firstActivity: Self.spread("09:42", "09:33", "10:05", 5),
                    lastActivity: Self.spread("17:50", "17:38", "18:25", 5)),
                WeekdayShape(
                    weekday: .fri, firstActivity: Self.spread("09:48", "09:30", "10:06", 2),
                    lastActivity: Self.spread("18:18", "18:15", "18:21", 2)),
            ])
    }

    @Test func daysOffOnTheSeedNeverContribute() throws {
        let (_, journal, _) = try DemoSeedTests.seeded()
        let from = SeriesTests.date("2026-10-01")
        let to = SeriesTests.date("2026-10-29")
        let before = try journal.dayShape(from: from, to: to)
        let summary = try journal.summary(from: from, to: to)

        // The leave day Fri 23 Oct and the weekend after it, each with an early start and a late end.
        try journal.startDay(SeriesTests.date("2026-10-23"), at: "05:00", actor: .cli)
        try journal.endDay(SeriesTests.date("2026-10-23"), at: "23:30", actor: .cli)
        try journal.startDay(SeriesTests.date("2026-10-24"), at: "04:30", actor: .cli)
        try journal.endDay(SeriesTests.date("2026-10-24"), at: "22:30", actor: .cli)

        #expect(try journal.dayShape(from: from, to: to) == before)
        #expect(try journal.summary(from: from, to: to).firstActivity == summary.firstActivity)
        #expect(try journal.summary(from: from, to: to).lastActivity == summary.lastActivity)
    }
}
