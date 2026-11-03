import Foundation
import Testing

@testable import CadenceCore

/// The twelve-month ACME demo (docs/PLAN.md T4.15): deterministic, synthetic, written only through `Journal`, and never
/// committed. The budget tests build it in a temporary folder and measure the app against it.
@Suite struct DemoYearTests {
    /// A Friday, the last day of the year demo and its open day.
    static let end = DemoSeed.yearEnd

    /// A store with `weeks` weeks of the year demo ending on `end`.
    static func store(weeks: Int = 52, path: String = TestStore.tempDirectory().appendingPathComponent("cadence.db").path) throws
        -> (store: SQLiteStore, journal: Journal, clock: ManualClock)
    {
        let clock = ManualClock(DemoSeed.yearStartInstant(endingOn: end, weeks: weeks))
        let store = try TestStore.make(path: path, clock: clock, projector: LedgerProjector())
        let ids = ULIDGenerator(clock: clock, random: SeededRandomSource(seed: 1))
        let journal = try Journal(store: store, config: DemoSeed.config(), clock: clock, ids: ids)
        try DemoSeed.year(into: journal, clock: clock, endingOn: end, weeks: weeks)
        return (store, journal, clock)
    }

    static func number(_ store: SQLiteStore, _ sql: String) throws -> Int64 {
        try store.db.first(sql)?.int("n") ?? -1
    }

    @Test func theYearStartsAtNineOnTheFirstDayOfItsWeeks() throws {
        let zone = TimeZone(identifier: DemoSeed.timezone)!
        let start = DemoSeed.yearStartInstant(endingOn: Self.end, weeks: 52)
        let first = DemoSeed.yearFirstDay(endingOn: Self.end, weeks: 52)
        #expect(Timestamp.clockTime(start, in: zone) == "09:00")
        #expect(DayBoundary.standard.day(of: start, in: zone) == first)
        #expect(first.weekday == .mon)
        #expect(first.days(until: Self.end) == 52 * 7 - 3)
        #expect(DemoSeed.yearEnd.weekday == .fri)
    }

    @Test func twoGenerationsGiveTheSameProjectionsAndTheSameChain() throws {
        let a = try Self.store(weeks: 6)
        let b = try Self.store(weeks: 6)
        #expect(try a.store.projectionDump() == b.store.projectionDump())
        #expect(try a.store.head()?.hash == b.store.head()?.hash)
        #expect(try a.store.eventCount() == b.store.eventCount())
        #expect(try a.store.eventCount() > 100)
    }

    @Test func aYearHasTheShapeOfARealOne() throws {
        let (store, journal, clock) = try Self.store()
        let first = DemoSeed.yearFirstDay(endingOn: Self.end, weeks: 52)
        let workdays = LocalDate.range(first, through: Self.end).filter { ![.sat, .sun].contains($0.weekday) }
        #expect(workdays.count == 260)

        // Every worked day but the last is wrapped up, a few are holidays or leave, and the last is open.
        let sealed = try Self.number(store, "SELECT COUNT(*) AS n FROM days WHERE sealed_at IS NOT NULL")
        let off = try Self.number(store, "SELECT COUNT(*) AS n FROM days WHERE kind IN ('holiday', 'leave_planned', 'leave_unplanned')")
        #expect(off >= 12 && off <= 40, "\(off) days off")
        #expect(sealed + off + 1 == Int64(workdays.count), "sealed \(sealed), off \(off), of \(workdays.count) workdays")
        let open = try #require(try store.db.first("SELECT sealed_at, first_activity FROM days WHERE date = ?", [.text(Self.end.description)]))
        #expect(open.text("sealed_at") == nil && open.text("first_activity") != nil)
        for kind in ["holiday", "leave_planned", "leave_unplanned"] {
            #expect(try Self.number(store, "SELECT COUNT(*) AS n FROM days WHERE kind = '\(kind)'") > 0, "no \(kind) day")
        }

        // Nothing happens on a weekend.
        for row in try store.db.query("SELECT date FROM days") {
            let day = try #require(row.text("date").flatMap { LocalDate($0) })
            #expect(![.sat, .sun].contains(day.weekday), "a row for the weekend day \(day)")
        }
        for row in try store.db.query("SELECT DISTINCT day FROM entries") {
            let day = try #require(row.text("day").flatMap { LocalDate($0) })
            #expect(![.sat, .sun].contains(day.weekday), "an entry on the weekend day \(day)")
        }

        // A realistic volume: a few thousand entries and some thousands of events, many collected PRs and reviews.
        let entries = try Self.number(store, "SELECT COUNT(*) AS n FROM entries")
        let events = try store.eventCount()
        #expect((2500...8000).contains(entries), "\(entries) entries")
        #expect((6000...16000).contains(events), "\(events) events")
        #expect(try Self.number(store, "SELECT COUNT(*) AS n FROM entries WHERE kind = 'pr.merged' AND origin = 'collected'") > 150)
        #expect(try Self.number(store, "SELECT COUNT(*) AS n FROM entries WHERE kind = 'review.given'") > 400)
        #expect(try Self.number(store, "SELECT COUNT(*) AS n FROM entries WHERE json_extract(attrs, '$.note') IS NOT NULL") > 100)
        #expect(try Self.number(store, "SELECT COUNT(*) AS n FROM genai_sessions") > 200)
        #expect(try Self.number(store, "SELECT COUNT(*) AS n FROM plan_tasks") > 800)

        // Synthetic and ACME only: PR links are on git.example.com, tickets are ACME's, and the title of every entry and
        // task is plain words.
        for row in try store.db.query("SELECT links FROM entries WHERE kind = 'pr.merged'") {
            #expect(row.text("links")?.contains("https://git.example.com/acme/") == true)
        }
        for row in try store.db.query("SELECT ticket_key FROM entries WHERE ticket_key IS NOT NULL") {
            #expect(row.text("ticket_key")?.hasPrefix("ACME-") == true)
        }

        // The ledger is whole, and its projections rebuild byte for byte.
        let report = try store.verifyChain()
        #expect(report.ok, "\(report.problems.prefix(3))")
        #expect(report.events == events)
        let live = try store.projectionDump()
        try store.rebuild()
        #expect(try store.projectionDump() == live)

        // Today is the last day, and reads as an open day with a plan in it.
        clock.set(Timestamp.resolve(Self.end, hour: 11, minute: 0, in: journal.zone))
        let context = try journal.dayContext(on: Self.end)
        #expect(context.view.day.sealedAt == nil)
        #expect(!context.view.tasks.isEmpty)
        #expect(context.rhythm.usual != nil, "a year of workdays gives a usual range")
    }

    @Test func aYearIsGeneratedInUnderTenSeconds() throws {
        let started = ContinuousClock.now
        _ = try Self.store()
        #expect(started.duration(to: .now) < .seconds(10))
    }
}
