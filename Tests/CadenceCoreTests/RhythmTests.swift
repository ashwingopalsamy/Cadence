import Foundation
import Testing

@testable import CadenceCore

/// The usual range read model (docs/SPEC.md sections 5.1 and 5.2, docs/PLAN.md T3.23): items logged per counted
/// workday, the middle 50% of the last 20, usual by now from `occurred_at`, usual plan size, and the pace words.
@Suite struct RhythmTests {
    static let kolkata = "Asia/Kolkata"
    static let newYork = "America/New_York"

    /// A journal over a fresh store whose clock reads `hour`:00 on `start` in Kolkata, with a way to write
    /// entries, tasks and day notes straight into the ledger.
    final class World {
        let clock: ManualClock
        let store: SQLiteStore
        let journal: Journal
        let boundary: DayBoundary
        private var serial = 0

        init(start: String = "2026-12-15", hour: Int = 18, boundary: DayBoundary = .standard) throws {
            let zone = TimeZone(identifier: RhythmTests.kolkata)!
            clock = ManualClock(Timestamp.resolve(LocalDate(start)!, hour: hour, minute: 0, in: zone))
            store = try TestStore.make(clock: clock, projector: LedgerProjector())
            var config = Config.defaults(timezone: RhythmTests.kolkata)
            config.dayBoundary = boundary
            self.boundary = boundary
            journal = try Journal(store: store, config: config, clock: clock, ids: CountingIDs())
        }

        /// The stored time for "HH:MM" on workday `day`: a time before the boundary is on the next calendar date.
        func stamp(_ day: String, _ clockText: String, zone zoneID: String = RhythmTests.kolkata) -> String {
            let date = LocalDate(day)!
            let zone = TimeZone(identifier: zoneID)!
            let minutes = Timestamp.parseClock(clockText).map { $0.0 * 60 + $0.1 }!
            let calendar = minutes < boundary.hour * 60 + boundary.minute ? date.adding(days: 1) : date
            return Timestamp.local(Timestamp.instant(clockTime: clockText, on: calendar, in: zone)!, in: zone)
        }

        /// One entry per element of `times`; nil is an entry with no `occurred_at`.
        func put(
            _ day: String, _ times: [String?], kind: EntryKind = .workDone, status: EntryStatus = .accepted,
            quantity: Int64 = 1, zone: String = RhythmTests.kolkata
        ) throws {
            var drafts: [EventDraft] = []
            for time in times {
                serial += 1
                let entry = Entry(
                    id: "E\(serial)", day: day, kind: kind, family: kind.defaultFamily, title: "Item \(serial)",
                    occurredAt: time.map { stamp(day, $0, zone: zone) }, quantity: quantity, origin: .selfReported,
                    status: status)
                drafts.append(EventPayload.entryCreated(entry).draft(actor: .cli))
            }
            try store.append(drafts)
        }

        /// `count` entries at 10:00 on `day`.
        func items(_ day: String, _ count: Int) throws { try put(day, Array(repeating: "10:00", count: count)) }

        func note(_ day: String, zone: String) throws {
            try store.append([EventPayload.dayNoted(DayNoted(day: day, tz: zone)).draft(actor: .app)])
        }

        @discardableResult
        func plan(_ day: String, _ count: Int, resolved: Bool = true) throws -> [PlanTask] {
            var tasks: [PlanTask] = []
            for _ in 0..<count {
                var task = try journal.planAdd(
                    title: "Task", day: LocalDate(day)!, estimateMin: nil, origin: .selfReported, actor: .cli)
                if resolved {
                    task = try journal.planResolve(taskID: task.id, status: .done, reason: nil, note: nil, links: [], actor: .cli)
                }
                tasks.append(task)
            }
            return tasks
        }

        func move(_ task: PlanTask) throws {
            try store.append([EventPayload.planResolved(PlanResolved(status: .moved)).draft(actor: .cli, id: task.id)])
        }
    }

    static func day(_ text: String) -> LocalDate { LocalDate(text)! }

    /// `local("2026-11-16", "12:00")` in Kolkata.
    static func local(_ day: String, _ clockText: String, zone: String = kolkata) -> Date {
        Timestamp.instant(clockTime: clockText, on: Self.day(day), in: TimeZone(identifier: zone)!)!
    }

    /// The first `count` Monday to Friday dates from `start`.
    static func workdays(from start: String, _ count: Int) -> [String] {
        var days: [String] = []
        var day = Self.day(start)
        while days.count < count {
            if ![Weekday.sat, .sun].contains(day.weekday) { days.append(day.description) }
            day = day.adding(days: 1)
        }
        return days
    }

    /// Ten workdays, Mon 2 Nov to Fri 13 Nov 2026.
    static let tenWorkdays = [
        "2026-11-02", "2026-11-03", "2026-11-04", "2026-11-05", "2026-11-06",
        "2026-11-09", "2026-11-10", "2026-11-11", "2026-11-12", "2026-11-13",
    ]

    // MARK: the pure range

    @Test func percentilesInterpolateBetweenRanksAndRoundHalfAwayFromZero() {
        // n = 10: ranks (n - 1) * p are 2.25, 4.5 and 6.75, so 3.25, 5.5 and 7.75 round to 3, 6 and 8.
        #expect(UsualRange.of(Array(1...10)) == UsualRange(low: 3, median: 6, high: 8, days: 10))
        // n = 11: ranks 2.5, 5 and 7.5 give 3.5, 6 and 8.5, and a half goes up.
        #expect(UsualRange.of(Array(1...11)) == UsualRange(low: 4, median: 6, high: 9, days: 11))
        // Five zeros then five ones: the median sits at rank 4.5, exactly half way, and rounds up to 1.
        #expect(UsualRange.of(Array(repeating: 0, count: 5) + Array(repeating: 1, count: 5)) == UsualRange(low: 0, median: 1, high: 1, days: 10))
        // A quarter rounds down (rank 2.25 between 0 and 1 is 0.25) and three quarters round up (6.75 gives 0.75).
        #expect(UsualRange.of([0, 0, 0] + Array(repeating: 1, count: 7)) == UsualRange(low: 0, median: 1, high: 1, days: 10))
        #expect(UsualRange.of(Array(repeating: 0, count: 7) + Array(repeating: 1, count: 3)) == UsualRange(low: 0, median: 0, high: 1, days: 10))
        #expect(UsualRange.of(Array(repeating: 4, count: 10)) == UsualRange(low: 4, median: 4, high: 4, days: 10))
    }

    @Test func fewerThanTenDaysGiveNoRange() {
        #expect(UsualRange.of([]) == nil)
        #expect(UsualRange.of(Array(1...9)) == nil)
        #expect(UsualRange.of(Array(1...10)) != nil)
    }

    @Test func theOrderOfTheValuesDoesNotMoveThePercentilesBelowTheCap() {
        #expect(UsualRange.of([10, 1, 9, 2, 8, 3, 7, 4, 6, 5]) == UsualRange.of(Array(1...10)))
    }

    @Test func onlyTheLastTwentyValuesCount() {
        // 1...25 oldest first: the last 20 are 6...25, ranks 4.75, 9.5 and 14.25 give 10.75, 15.5 and 20.25.
        #expect(UsualRange.of(Array(1...25)) == UsualRange(low: 11, median: 16, high: 20, days: 20))
        // Seven old outliers fall out of the window.
        #expect(UsualRange.of(Array(repeating: 100, count: 7) + Array(repeating: 1, count: 20)) == UsualRange(low: 1, median: 1, high: 1, days: 20))
    }

    @Test func aCountIsMoreAboveTheHighFewerBelowTheLowAndUsualOtherwise() {
        let range = UsualRange(low: 4, median: 5, high: 5, days: 19)
        #expect(Pace.of(3, against: range) == .fewer)
        #expect(Pace.of(4, against: range) == .usual)
        #expect(Pace.of(5, against: range) == .usual)
        #expect(Pace.of(6, against: range) == .more)
        let flat = UsualRange(low: 0, median: 1, high: 1, days: 10)
        #expect(Pace.of(0, against: flat) == .usual)
        #expect(Pace.of(2, against: flat) == .more)
        // The range bounds are inclusive on both sides.
        let single = UsualRange(low: 2, median: 2, high: 2, days: 10)
        #expect([1, 2, 3].map { Pace.of($0, against: single) } == [.fewer, .usual, .more])
    }

    @Test func noByNowRangeMeansNoPace() {
        let none = Rhythm(today: 3, usual: nil, byNow: nil, plan: nil, points: [])
        #expect(none.pace == nil)
        let some = Rhythm(today: 9, usual: nil, byNow: UsualRange(low: 4, median: 5, high: 6, days: 12), plan: nil, points: [])
        #expect(some.pace == .more)
    }

    // MARK: minutes since the day boundary

    @Test func minutesSinceTheBoundaryCountFromFourAndWrapAtMidnight() {
        let boundary = DayBoundary.standard
        let kolkata = TimeZone(identifier: Self.kolkata)!
        func minutes(_ day: String, _ clockText: String) -> Int {
            boundary.minutesSinceBoundary(Self.local(day, clockText), in: kolkata)
        }
        #expect(minutes("2026-11-16", "04:00") == 0)
        #expect(minutes("2026-11-16", "12:00") == 480)
        #expect(minutes("2026-11-17", "01:00") == 21 * 60)  // late in the day that began on the 16th
        #expect(minutes("2026-11-17", "03:59") == 24 * 60 - 1)
        let late = DayBoundary("06:30")!
        #expect(late.minutesSinceBoundary(Self.local("2026-11-16", "06:30"), in: kolkata) == 0)
        #expect(late.minutesSinceBoundary(Self.local("2026-11-16", "07:00"), in: kolkata) == 30)
        #expect(late.minutesSinceBoundary(Self.local("2026-11-16", "06:29"), in: kolkata) == 24 * 60 - 1)
        // The same instant is a different time of day in another zone.
        let instant = Self.local("2026-11-16", "12:00")
        #expect(boundary.minutesSinceBoundary(instant, in: TimeZone(identifier: Self.newYork)!) == 1290)  // 01:30 in New York, late
    }

    // MARK: counted workdays and gaps

    @Test func gapsAreSkippedAndNeverCountedAsZero() throws {
        let w = try World()
        // Counted workdays, oldest first: 2, 4, 6, 8, 10, 3, 5, 7, 9, 1, 11, 12, 4 and 6 items.
        let counted: [(String, Int)] = [
            ("2026-11-02", 2), ("2026-11-03", 4), ("2026-11-04", 5), ("2026-11-05", 8), ("2026-11-06", 10),
            ("2026-11-09", 3), ("2026-11-16", 5), ("2026-11-17", 7), ("2026-11-18", 9), ("2026-11-19", 1),
            ("2026-11-20", 11), ("2026-11-23", 12), ("2026-11-24", 4), ("2026-11-25", 6),
        ]
        for (day, count) in counted { try w.items(day, count) }
        // Left out: a weekend, leave, a holiday, a workday with only AI and presence entries, and a workday with only
        // proposed ones. None of them is a zero.
        try w.items("2026-11-07", 50)
        try w.items("2026-11-10", 40)
        try w.journal.declare(Self.day("2026-11-10"), kind: .leavePlanned, label: nil, actor: .cli)
        try w.items("2026-11-11", 40)
        try w.journal.declare(Self.day("2026-11-11"), kind: .holiday, label: nil, actor: .cli)
        try w.put("2026-11-12", Array(repeating: "11:00", count: 5), kind: .genaiSession)
        try w.put("2026-11-12", Array(repeating: "11:00", count: 5), kind: .note)
        try w.put("2026-11-13", Array(repeating: "11:00", count: 5), status: .proposed)
        // On a counted day, AI, presence and proposed entries add nothing, and a row is one item whatever its quantity.
        try w.put("2026-11-03", Array(repeating: "12:00", count: 3), kind: .genaiSession)
        try w.put("2026-11-03", Array(repeating: "12:00", count: 3), kind: .note)
        try w.put("2026-11-03", Array(repeating: "12:00", count: 3), status: .proposed)
        try w.put("2026-11-04", ["10:00"], quantity: 5)  // the sixth item of the 4th, not five more
        // Nothing at all on the 26th yet, and the 21st and 22nd are a weekend.

        let ref = Self.day("2026-11-26")
        let r = try w.journal.rhythm(on: ref, at: Self.local("2026-11-26", "12:00"))
        // Sorted: 1 2 3 4 4 5 6 6 7 8 9 10 11 12 (n = 14). Ranks 3.25, 6.5 and 9.75 give 4, 6 and 8.75 (so 9).
        #expect(r.usual == UsualRange(low: 4, median: 6, high: 9, days: 14))
        #expect(r.today == 0)

        // The band as it stood on each date, from the days before it only.
        func point(_ day: String) throws -> RhythmPoint { try #require(r.points.first { $0.date == Self.day(day) }) }
        #expect(r.points.count == 28)
        #expect(r.points.first?.date == Self.day("2026-10-30") && r.points.last?.date == ref)
        for gap in ["2026-11-07", "2026-11-08", "2026-11-10", "2026-11-11", "2026-11-12", "2026-11-13", "2026-11-14", "2026-11-15", "2026-11-21", "2026-11-22", "2026-11-26"] {
            #expect(try point(gap).items == nil, "\(gap)")
        }
        #expect(try point("2026-11-03").items == 4)
        #expect(try point("2026-11-09").items == 3)
        #expect(try point("2026-11-19").usual == nil)  // nine counted days before it
        #expect(try point("2026-11-20").usual == UsualRange(low: 3, median: 6, high: 8, days: 10))  // 2 4 6 8 10 3 5 7 9 1
        #expect(try point("2026-11-20").items == 11)
        #expect(try point("2026-11-23").usual == UsualRange(low: 4, median: 6, high: 9, days: 11))
        #expect(try point("2026-11-26").usual == r.usual)
        // A gap day still shows the band as it stood: the 21st came after ten counted days.
        #expect(try point("2026-11-21").usual == UsualRange(low: 4, median: 6, high: 9, days: 11))
    }

    @Test func aDeclaredWorkdayOnAWeekendCountsAndAWeekdayOfLeaveDoesNot() throws {
        let w = try World()
        for day in Self.tenWorkdays.prefix(9) { try w.items(day, 3) }
        let ref = Self.day("2026-11-16")
        // Nine counted workdays: still learning.
        #expect(try w.journal.rhythm(on: ref).usual == nil)
        try w.items("2026-11-14", 3)  // a Saturday
        #expect(try w.journal.rhythm(on: ref).usual == nil)
        try w.journal.declare(Self.day("2026-11-14"), kind: .workday, label: nil, actor: .cli)
        #expect(try w.journal.rhythm(on: ref).usual == UsualRange(low: 3, median: 3, high: 3, days: 10))
        // One of the ten is leave after all: back to nine.
        try w.journal.declare(Self.day("2026-11-12"), kind: .leaveUnplanned, label: nil, actor: .cli)
        #expect(try w.journal.rhythm(on: ref).usual == nil)
    }

    @Test func onlyDaysStrictlyBeforeTheReferenceDayCount() throws {
        let w = try World()
        for day in Self.tenWorkdays { try w.items(day, 3) }
        try w.items("2026-11-16", 50)
        try w.items("2026-11-17", 50)
        let monday = try w.journal.rhythm(on: Self.day("2026-11-16"), at: Self.local("2026-11-16", "23:00"))
        #expect(monday.usual == UsualRange(low: 3, median: 3, high: 3, days: 10))
        #expect(monday.today == 50)
        #expect(monday.points.last?.items == 50)
        // The next day reads the 16th as one of the days before it, and not the 17th or later ones.
        let tuesday = try w.journal.rhythm(on: Self.day("2026-11-17"), at: Self.local("2026-11-17", "23:00"))
        #expect(tuesday.usual?.days == 11)
        #expect(tuesday.today == 50)
        // And it does not matter that those later days exist when asking about an earlier one.
        let early = try w.journal.rhythm(on: Self.day("2026-11-13"), at: Self.local("2026-11-13", "23:00"))
        #expect(early.usual == nil)  // nine days before the 13th
        #expect(early.today == 3)
    }

    @Test func theLastTwentyCountedWorkdaysFormTheWindow() throws {
        let w = try World()
        // Mon 2 Nov to Fri 4 Dec 2026 is 25 workdays; day k has k items, all at 10:00.
        for (index, day) in Self.workdays(from: "2026-11-02", 25).enumerated() { try w.items(day, index + 1) }
        let r = try w.journal.rhythm(on: Self.day("2026-12-07"), at: Self.local("2026-12-07", "12:00"))
        // Days 6 to 25 are the last twenty: values 6...25.
        #expect(r.usual == UsualRange(low: 11, median: 16, high: 20, days: 20))
        // Every item was logged by 10:00, so by 12:00 the day is complete and the by-now range is the same.
        #expect(r.byNow == r.usual)
    }

    // MARK: usual by now

    /// Ten workdays with four items each: 10:00, 14:00, 01:00 after the boundary (late in the day) and one with no
    /// `occurred_at`.
    static func daysWithFourItems(_ w: World) throws {
        for day in tenWorkdays { try w.put(day, ["10:00", "14:00", "01:00", nil]) }
    }

    @Test func anEntryAfterMidnightIsLateInTheDayAndOneWithNoTimeNeverCountsByNow() throws {
        let w = try World()
        try Self.daysWithFourItems(w)
        try w.put("2026-11-16", ["09:00", "11:00"])
        let ref = Self.day("2026-11-16")
        func byNow(_ day: String, _ time: String) throws -> UsualRange? {
            try w.journal.rhythm(on: ref, at: Self.local(day, time)).byNow
        }
        func flat(_ n: Int) -> UsualRange { UsualRange(low: n, median: n, high: n, days: 10) }

        // The whole day is four items, the one with no time included.
        let noon = try w.journal.rhythm(on: ref, at: Self.local("2026-11-16", "12:00"))
        #expect(noon.usual == flat(4))
        #expect(noon.byNow == flat(1))  // only the 10:00 item is at or before 12:00
        #expect(noon.today == 2)
        #expect(noon.pace == .more)  // two items against a usual one by now

        #expect(try byNow("2026-11-16", "09:59") == flat(0))
        #expect(try byNow("2026-11-16", "10:00") == flat(1))  // at or before
        #expect(try byNow("2026-11-16", "13:59") == flat(1))
        #expect(try byNow("2026-11-16", "14:00") == flat(2))
        #expect(try byNow("2026-11-16", "23:59") == flat(2))
        // 01:00 is late, not early: it joins only once the clock itself has passed 01:00 of the next morning.
        #expect(try byNow("2026-11-17", "00:59") == flat(2))
        #expect(try byNow("2026-11-17", "01:00") == flat(3))
        #expect(try byNow("2026-11-17", "03:59") == flat(3))  // and the entry with no time never joins
    }

    @Test func aBoundaryOtherThanFourMovesWhereTheDayStarts() throws {
        let w = try World(boundary: DayBoundary("06:00")!)
        // 05:00 belongs to the day before and is its last hour; 06:30 is its first.
        for day in Self.tenWorkdays { try w.put(day, ["06:30", "05:00"]) }
        let ref = Self.day("2026-11-16")
        func flat(_ n: Int) -> UsualRange { UsualRange(low: n, median: n, high: n, days: 10) }
        #expect(try w.journal.rhythm(on: ref, at: Self.local("2026-11-16", "08:00")).byNow == flat(1))
        #expect(try w.journal.rhythm(on: ref, at: Self.local("2026-11-17", "05:00")).byNow == flat(2))
        #expect(try w.journal.rhythm(on: ref, at: Self.local("2026-11-16", "06:29")).byNow == flat(0))
    }

    @Test func byNowIsNilUnderTenDaysAndOnlyCountsDaysThatAreCounted() throws {
        let w = try World()
        for day in Self.tenWorkdays.prefix(9) { try w.put(day, ["10:00"]) }
        let ref = Self.day("2026-11-16")
        let at = Self.local("2026-11-16", "12:00")
        #expect(try w.journal.rhythm(on: ref, at: at).byNow == nil)
        // A day whose only entries are late and have no time is a counted day with a by-now count of zero, not a gap.
        try w.put("2026-11-13", ["22:00", nil])
        #expect(try w.journal.rhythm(on: ref, at: at).byNow == UsualRange(low: 1, median: 1, high: 1, days: 10))
        let early = try w.journal.rhythm(on: ref, at: Self.local("2026-11-16", "09:00")).byNow
        #expect(early == UsualRange(low: 0, median: 0, high: 0, days: 10))
    }

    @Test func aDayInAnotherZoneIsMeasuredInItsOwnZone() throws {
        let w = try World()
        // Ten days recorded in New York, one entry each at 05:00 there: an hour into the day, but 15:30 in Kolkata.
        for day in Self.tenWorkdays {
            try w.note(day, zone: Self.newYork)
            try w.put(day, ["05:00"], zone: Self.newYork)
        }
        // 12:00 in Kolkata is 480 minutes into the reference day. In its own zone each entry is 60 minutes in, so it
        // counts; measured in Kolkata it would be 690 and would not.
        let r = try w.journal.rhythm(on: Self.day("2026-11-16"), at: Self.local("2026-11-16", "12:00"))
        #expect(r.byNow == UsualRange(low: 1, median: 1, high: 1, days: 10))
    }

    @Test func theReferenceInstantIsMeasuredInTheReferenceDaysZone() throws {
        let w = try World()
        for day in Self.tenWorkdays { try w.put(day, ["06:00"]) }  // 120 minutes into each Kolkata day
        let ref = "2026-11-16"
        try w.note(ref, zone: Self.newYork)
        // 09:30Z is 04:30 in New York (30 minutes into the day), but 15:00 in Kolkata (660 minutes in).
        let instant = Timestamp.parse("2026-11-16T09:30:00Z")!
        let r = try w.journal.rhythm(on: Self.day(ref), at: instant)
        #expect(r.byNow == UsualRange(low: 0, median: 0, high: 0, days: 10))
    }

    // MARK: usual plan size

    @Test func planSizeIsThePercentilesOfTasksPlannedPerWorkday() throws {
        let w = try World()
        for (day, count) in zip(Self.tenWorkdays, [3, 4, 5, 2, 3, 4, 6, 3, 5, 4]) { try w.plan(day, count) }
        // Sorted: 2 3 3 3 4 4 4 5 5 6. Ranks 2.25, 4.5 and 6.75 give 3, 4 and 4.75 (so 5).
        let r = try w.journal.rhythm(on: Self.day("2026-11-16"), at: Self.local("2026-11-16", "12:00"))
        #expect(r.plan == UsualRange(low: 3, median: 4, high: 5, days: 10))
        // The 13th has only nine planned workdays before it.
        #expect(try w.journal.rhythm(on: Self.day("2026-11-13")).plan == nil)
    }

    @Test func planSizeLeavesOutMovedAfterSealAndDaysThatAreNotPlannedWorkdays() throws {
        let w = try World()
        // Ten workdays of 3 tasks. Each left-out kind below would lift three of them to 4, and the 75th percentile with them.
        for day in Self.tenWorkdays { try w.plan(day, 3) }
        // Moved tasks are not planned on the day they left (the 6th, 9th and 10th).
        for day in ["2026-11-06", "2026-11-09", "2026-11-10"] {
            for task in try w.plan(day, 1) { try w.move(task) }
        }
        // Tasks added after the wrap-up are left out too (the 3rd, 4th and 5th): the day is sealed, one more comes after.
        for day in ["2026-11-03", "2026-11-04", "2026-11-05"] {
            #expect(try w.journal.seal(Self.day(day), actor: .cli).carried.isEmpty)
            #expect(try w.plan(day, 1).map(\.afterSeal) == [true])
        }
        // A Saturday with a plan, a holiday with a plan, and a workday with no plan are not planned workdays.
        try w.plan("2026-11-07", 9)
        try w.plan("2026-11-16", 7)
        try w.journal.declare(Self.day("2026-11-16"), kind: .holiday, label: nil, actor: .cli)
        // The reference day and later ones are not read.
        try w.plan("2026-11-18", 12)
        try w.plan("2026-11-19", 12)

        let r = try w.journal.rhythm(on: Self.day("2026-11-18"), at: Self.local("2026-11-18", "12:00"))
        #expect(r.plan == UsualRange(low: 3, median: 3, high: 3, days: 10))
    }

    @Test func planSizeKeepsTheLastTwentyPlannedWorkdays() throws {
        let w = try World()
        // 30 workdays from Mon 2 Nov: the first ten plan 12 tasks, the next twenty plan 2.
        for (index, day) in Self.workdays(from: "2026-11-02", 30).enumerated() {
            try w.plan(day, index < 10 ? 12 : 2, resolved: false)
        }
        let r = try w.journal.rhythm(on: Self.day("2026-12-14"))
        #expect(r.plan == UsualRange(low: 2, median: 2, high: 2, days: 20))
    }

    // MARK: reading

    @Test func anEmptyStoreHasNoRangeAndOnlyGaps() throws {
        let clock = ManualClock(Timestamp.parse("2026-11-16T06:30:00Z")!)  // Mon 16 Nov, 12:00 in Kolkata
        let store = try TestStore.make(clock: clock, projector: LedgerProjector())
        let journal = try Journal(
            store: store, config: Config.defaults(timezone: Self.kolkata), clock: clock, ids: CountingIDs(), actor: .mcp,
            writesGenesis: false)
        let r = try journal.rhythm()
        #expect(r.today == 0 && r.usual == nil && r.byNow == nil && r.plan == nil && r.pace == nil)
        #expect(r.points.count == 28)
        #expect(r.points.allSatisfy { $0.items == nil && $0.usual == nil })
        #expect(try store.eventCount() == 0)
    }

    @Test func theDefaultsAreTodayAndNowAndTheWindowIsTwentyEightDays() throws {
        let w = try World(start: "2026-11-16", hour: 12)
        try Self.daysWithFourItems(w)
        try w.put("2026-11-16", ["09:00", "11:00"])
        let implicit = try w.journal.rhythm()
        let explicit = try w.journal.rhythm(on: Self.day("2026-11-16"), at: w.clock.now(), window: 28)
        #expect(implicit == explicit)
        #expect(implicit.points.count == 28 && implicit.points.last?.date == Self.day("2026-11-16"))
        #expect(implicit.byNow == UsualRange(low: 1, median: 1, high: 1, days: 10))
        // An instant with no day names its own day: 02:00 on the 17th is late on the 16th.
        let late = try w.journal.rhythm(at: Self.local("2026-11-17", "02:00"))
        #expect(late.points.last?.date == Self.day("2026-11-16"))
        #expect(late.byNow == UsualRange(low: 3, median: 3, high: 3, days: 10))
        #expect(try w.journal.rhythm(window: 3).points.map(\.date) == ["2026-11-14", "2026-11-15", "2026-11-16"].map(Self.day))
    }

    @Test func aWindowOutsideOneToThreeSixtySixIsRefused() throws {
        let w = try World()
        #expect(throws: CadenceError.self) { try w.journal.rhythm(window: 0) }
        #expect(throws: CadenceError.self) { try w.journal.rhythm(window: -1) }
        #expect(throws: CadenceError.self) { try w.journal.rhythm(window: 367) }
        #expect(try w.journal.rhythm(window: 1).points.count == 1)
        #expect(try w.journal.rhythm(window: 366).points.count == 366)
    }

    @Test func readingTheRhythmNeverWritesToTheLedger() throws {
        let w = try World()
        try Self.daysWithFourItems(w)
        try w.plan("2026-11-02", 2)
        let before = try w.store.eventCount()
        _ = try w.journal.rhythm()
        _ = try w.journal.rhythm(on: Self.day("2026-11-16"), window: 60)
        #expect(try w.store.eventCount() == before)
    }

    // MARK: the October demo

    /// The demo script's items per day: merged PRs, reviews and logs, with the week notes left out (a note is
    /// presence, and AI sessions are not entries). By hand, from the day scripts in DemoSeed:
    ///
    ///     day      PRs  reviews  logs  items
    ///     Oct  1    1      3       1      5     Oct 14   1   3   1   5     Oct 22   0   1   1   2
    ///     Oct  5    1      2       1      4     Oct 15   0   2   1   3     Oct 26   1   3   3   7
    ///     Oct  6    0      2       1      3     Oct 16   1   3   1   5     Oct 27   1   3   4   8
    ///     Oct  7    1      3       1      5     Oct 19   0   2   1   3     Oct 28   1   3   4   8
    ///     Oct  8    1      2       1      4     Oct 20   1   2   1   4     Oct 29   1   3   2   6
    ///     Oct  9    1      3       1      5     Oct 21   1   3   1   5
    ///     Oct 12    0      2       1      3
    ///     Oct 13    1      2       1      4
    ///
    /// That is 19 counted workdays and 89 items: 14 PRs, 47 reviews and 28 logs. Oct 2 is a holiday, Oct 23 is leave,
    /// and the weekends are gaps.
    static let octoberItems: [Int: Int] = [
        1: 5, 5: 4, 6: 3, 7: 5, 8: 4, 9: 5, 12: 3, 13: 4, 14: 5, 15: 3, 16: 5, 19: 3, 20: 4, 21: 5, 22: 2, 26: 7,
        27: 8, 28: 8, 29: 6,
    ]

    @Test func theOctoberSeedGivesTheHandCountedItemsPerDay() throws {
        let (_, journal, _) = try DemoSeedTests.seeded()
        let r = try journal.rhythm(on: Self.day("2026-10-29"), at: Self.local("2026-10-29", "18:00"), window: 29)
        #expect(r.points.map(\.date) == (1...29).map { Self.day("2026-10-" + LocalDate.pad($0, 2)) })
        #expect(r.points.map(\.items) == (1...29).map { Self.octoberItems[$0] })
        #expect(r.points.compactMap(\.items).reduce(0, +) == 89)
        #expect(r.points.compactMap(\.items).count == 19)
        #expect(r.today == 6)
    }

    @Test func theOctoberSeedGivesTheHandComputedUsualRange() throws {
        let (_, journal, _) = try DemoSeedTests.seeded()
        // On Fri 30 Oct, 19 counted workdays lie before. Sorted: 2, 3 x4, 4 x4, 5 x6, 6, 7, 8 x2 (idx 0 to 18).
        // Ranks (n - 1) * p = 4.5, 9 and 13.5: 3.5 rounds to 4, then 5, then 5.
        let friday = try journal.rhythm(on: Self.day("2026-10-30"), at: Self.local("2026-10-30", "13:00"))
        #expect(friday.usual == UsualRange(low: 4, median: 5, high: 5, days: 19))
        #expect(friday.today == 0)
        // On Thu 29 Oct the 29th itself (6) is left out. Sorted: 2, 3 x4, 4 x4, 5 x6, 7, 8 x2 (n = 18).
        // Ranks 4.25, 8.5 and 12.75: 3.25 rounds to 3, 4.5 rounds to 5 (away from zero), 5.
        let thursday = try journal.rhythm(on: Self.day("2026-10-29"), at: Self.local("2026-10-29", "13:00"))
        #expect(thursday.usual == UsualRange(low: 3, median: 5, high: 5, days: 18))
        #expect(thursday.today == 6)
    }

    @Test func theOctoberBandAsItStoodOnEachDate() throws {
        let (_, journal, _) = try DemoSeedTests.seeded()
        // Seven dates, Oct 14 to Oct 20. Counted before Oct 16: Oct 1, 5, 6, 7, 8, 9, 12, 13, 14, 15 with 5 4 3 5 4 5 3 4 5 3,
        // sorted 3 3 3 4 4 4 5 5 5 5 (n = 10), ranks 2.25, 4.5 and 6.75: 3.25, 4 and 5 give 3, 4, 5.
        // Adding Oct 16 (5): n = 11, ranks 2.5, 5 and 7.5 give 3.5, 4 and 5, so 4, 4, 5.
        // Adding Oct 19 (3): n = 12, ranks 2.75, 5.5 and 8.25 give 3, 4 and 5.
        let r = try journal.rhythm(on: Self.day("2026-10-20"), at: Self.local("2026-10-20", "18:00"), window: 7)
        let expected: [(day: String, items: Int?, usual: UsualRange?)] = [
            ("2026-10-14", 5, nil),  // eight counted days before: still learning
            ("2026-10-15", 3, nil),  // nine
            ("2026-10-16", 5, UsualRange(low: 3, median: 4, high: 5, days: 10)),
            ("2026-10-17", nil, UsualRange(low: 4, median: 4, high: 5, days: 11)),  // a Saturday keeps the band, with no point
            ("2026-10-18", nil, UsualRange(low: 4, median: 4, high: 5, days: 11)),
            ("2026-10-19", 3, UsualRange(low: 4, median: 4, high: 5, days: 11)),
            ("2026-10-20", 4, UsualRange(low: 3, median: 4, high: 5, days: 12)),
        ]
        #expect(r.points == expected.map { RhythmPoint(date: Self.day($0.day), items: $0.items, usual: $0.usual) })
        #expect(r.usual == UsualRange(low: 3, median: 4, high: 5, days: 12))
    }

    @Test func theOctoberSeedGivesTheHandComputedPlanSize() throws {
        let (_, journal, _) = try DemoSeedTests.seeded()
        // Planned per day, moved originals out and the carried copies in (each copy is planned on the next workday):
        // tasks - carried out + carried in. Oct 1 5-1+0=4, Oct 5 3+1=4, Oct 6 5-1=4, Oct 7 3+1=4, Oct 8 4, Oct 9 4,
        // Oct 12 4, Oct 13 5-1=4, Oct 14 4-1+1=4, Oct 15 3+1=4, Oct 16 4-1=3, Oct 19 2+1=3, Oct 20 3, Oct 21 3,
        // Oct 22 3, Oct 26 5, Oct 27 4, Oct 28 5, Oct 29 4. They add to 73, the spec's 73 counted tasks.
        // On Oct 30, 19 days before: 3 x5, 4 x12, 5 x2. Ranks 4.5, 9 and 13.5: 3.5 rounds to 4, then 4, 4.
        let friday = try journal.rhythm(on: Self.day("2026-10-30"), at: Self.local("2026-10-30", "13:00"))
        #expect(friday.plan == UsualRange(low: 4, median: 4, high: 4, days: 19))
        // On Oct 29, 18 days before: 3 x5, 4 x11, 5 x2. Ranks 4.25, 8.5 and 12.75: 3.25 rounds to 3, then 4, 4.
        let thursday = try journal.rhythm(on: Self.day("2026-10-29"), at: Self.local("2026-10-29", "13:00"))
        #expect(thursday.plan == UsualRange(low: 3, median: 4, high: 4, days: 18))
    }

    /// The seed's entry times are jittered but fixed, so the counts by a time of day are read off the seed and not
    /// derived from the scripts. They are checked below against the stored clock text (`substr(occurred_at, 12, 5)`, the
    /// local time in Kolkata), which is a different road from the zone arithmetic the read model uses. Items by then on Oct 1, 5, 6,
    /// 7, 8, 9, 12, 13, 14, 15, 16, 19, 20, 21, 22, 26, 27, 28 and 29.
    ///
    /// By 13:00, sorted: 1 x6, 2 x10, 3 x3 (idx 0 to 18). Ranks 4.5, 9 and 13.5 give 1, 2 and 2.
    /// By 15:00, sorted: 1, 2 x4, 3 x6, 4 x6, 5 x2. Ranks 4.5, 9 and 13.5: 2.5 rounds to 3, then 3, then 4.
    static let octoberByNow: [(time: String, perDay: [Int], expected: UsualRange)] = [
        ("13:00", [2, 2, 1, 2, 2, 2, 1, 2, 2, 1, 1, 1, 2, 2, 1, 3, 3, 2, 3], UsualRange(low: 1, median: 2, high: 2, days: 19)),
        ("15:00", [4, 3, 2, 3, 3, 4, 2, 3, 4, 2, 3, 2, 3, 4, 1, 5, 5, 4, 4], UsualRange(low: 3, median: 3, high: 4, days: 19)),
    ]

    @Test func theOctoberSeedByNowMidDayFollowsTheClockOfEachDay() throws {
        let (store, journal, _) = try DemoSeedTests.seeded()
        let counted = Self.octoberItems.keys.sorted()
        for (time, perDay, expected) in Self.octoberByNow {
            var oracle: [Int: Int] = [:]
            for row in try store.db.query(
                """
                SELECT day, COUNT(*) AS n FROM entries
                WHERE status = 'accepted' AND family NOT IN ('presence', 'ai') AND substr(occurred_at, 12, 5) <= ? AND day < '2026-10-30'
                GROUP BY day
                """, [.text(time)])
            {
                oracle[Int(row.text("day")!.suffix(2))!] = Int(row.int("n")!)
            }
            #expect(counted.map { oracle[$0] ?? 0 } == perDay, "\(time)")
            #expect(UsualRange.of(perDay) == expected, "\(time)")
            let r = try journal.rhythm(on: Self.day("2026-10-30"), at: Self.local("2026-10-30", time))
            #expect(r.byNow == expected, "\(time)")
            // Nothing is logged on the 30th yet: below the by-now low, so fewer.
            #expect(r.pace == .fewer, "\(time)")
        }
    }

    @Test func theOctoberSeedByNowAtTheEdgesOfTheDay() throws {
        let (_, journal, _) = try DemoSeedTests.seeded()
        let ref = Self.day("2026-10-30")
        // Nothing is logged before 10:00 (the day starts at 09:30 to 10:15 and the first item is 30 minutes later), so
        // at the boundary and at 09:59 every counted day has a count of zero, which is a count and not a gap.
        for time in ["04:00", "09:59"] {
            #expect(try journal.rhythm(on: ref, at: Self.local("2026-10-30", time)).byNow == UsualRange(low: 0, median: 0, high: 0, days: 19), "\(time)")
        }
        // Every item is in by 18:00 (the wrap-up is from 17:20, and items stop 45 minutes before it), so the later in the
        // day the range is the full-day one.
        for time in ["18:00", "23:59"] {
            #expect(try journal.rhythm(on: ref, at: Self.local("2026-10-30", time)).byNow == UsualRange(low: 4, median: 5, high: 5, days: 19), "\(time)")
        }
    }
}
