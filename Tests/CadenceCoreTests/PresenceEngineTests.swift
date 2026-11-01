import Foundation
import Testing

@testable import CadenceCore

/// The presence engine writing through the Journal (docs/SPEC.md sections 3, 7.3, 8.4 and 10.1).
@Suite struct PresenceEngineTests {
    static let zoneID = "Asia/Kolkata"
    static let zone = TimeZone(identifier: zoneID)!

    static func at(_ date: String, _ hour: Int, _ minute: Int, _ second: Int = 0) -> Date {
        PresenceMachineTests.at(date, hour, minute, second)
    }

    struct Setup {
        let store: SQLiteStore
        let clock: ManualClock
        let journal: Journal

        func engine(restoring machine: PresenceMachine? = nil) -> PresenceEngine {
            PresenceEngine(journal: journal, clock: clock, restoring: machine)
        }

        /// A second journal on the same store, as the app would open after a config change.
        func journal(timezone: String) throws -> Journal {
            try Journal(store: store, config: Config.defaults(timezone: timezone), clock: clock, ids: CountingIDs())
        }

        func spans() throws -> [(day: String, start: String, end: String, source: String)] {
            try store.db.query("SELECT day, start_at, end_at, source FROM presence_spans ORDER BY start_at, id").map {
                ($0.text("day") ?? "", $0.text("start_at") ?? "", $0.text("end_at") ?? "", $0.text("source") ?? "")
            }
        }

        func events(_ type: String) throws -> [Event] {
            try store.readEvents("SELECT * FROM events WHERE type = ? ORDER BY seq", [.text(type)])
        }
    }

    func setup(at start: Date = at("2026-10-29", 8, 0)) throws -> Setup {
        let clock = ManualClock(start)
        let store = try TestStore.make(clock: clock, projector: LedgerProjector())
        let journal = try Journal(
            store: store, config: Config.defaults(timezone: Self.zoneID), clock: clock, ids: CountingIDs())
        return Setup(store: store, clock: clock, journal: journal)
    }

    /// Moves the clock to `t` and hands the engine one event.
    func send(_ engine: PresenceEngine, _ s: Setup, _ event: PresenceEvent, at t: Date) throws {
        s.clock.set(t)
        try engine.handle(event)
    }

    func active(_ engine: PresenceEngine, _ s: Setup, from: Date, to: Date, step: TimeInterval = 30) throws {
        var t = from
        while t <= to {
            try send(engine, s, .sample(idleSeconds: 0, unlocked: true), at: t)
            t = t.addingTimeInterval(step)
        }
    }

    // MARK: - Writes

    @Test func writesTheSpanAndTheDayStartAsTheApp() throws {
        let s = try setup()
        let engine = s.engine()
        try active(engine, s, from: Self.at("2026-10-29", 9, 0), to: Self.at("2026-10-29", 12, 0))
        try send(engine, s, .lock, at: Self.at("2026-10-29", 12, 1))

        let started = try s.events("day.started")
        #expect(started.count == 1)
        #expect(started.first?.actor == .app)
        let mark = try DayMark(json: try #require(started.first).data)
        #expect(mark == DayMark(day: "2026-10-29", tz: Self.zoneID, at: "2026-10-29T09:00:00+05:30", source: .input))

        #expect(try s.spans().map(\.start) == ["2026-10-29T09:00:00+05:30"])
        #expect(try s.spans().map(\.end) == ["2026-10-29T12:01:00+05:30"])
        #expect(try s.spans().map(\.source) == ["input"])
        let view = try s.journal.dayView(LocalDate("2026-10-29")!)
        #expect(view.day.firstActivity == "2026-10-29T09:00:00+05:30")
        #expect(view.day.lastActivity == "2026-10-29T12:01:00+05:30")
    }

    @Test func nothingIsWrittenBeforeInput() throws {
        let s = try setup()
        let engine = s.engine()
        let before = try s.store.eventCount()
        try send(engine, s, .wake, at: Self.at("2026-10-29", 9, 0))
        try send(engine, s, .unlock, at: Self.at("2026-10-29", 9, 0, 5))
        try send(engine, s, .sample(idleSeconds: 30, unlocked: true), at: Self.at("2026-10-29", 9, 0, 30))
        #expect(try s.store.eventCount() == before)
        #expect(try s.journal.dayView(LocalDate("2026-10-29")!).day.firstActivity == nil)
    }

    @Test func aSpanAcrossTheBoundaryLandsOnTwoDaysCutAt0400() throws {
        let s = try setup(at: Self.at("2026-10-29", 22, 0))
        let engine = s.engine()
        try active(engine, s, from: Self.at("2026-10-29", 23, 0), to: Self.at("2026-10-30", 5, 0), step: 60)
        try send(engine, s, .sample(idleSeconds: 300, unlocked: true), at: Self.at("2026-10-30", 5, 5))
        let spans = try s.spans()
        #expect(spans.map(\.day) == ["2026-10-29", "2026-10-30"])
        #expect(spans.map(\.start) == ["2026-10-29T23:00:00+05:30", "2026-10-30T04:00:00+05:30"])
        #expect(spans.map(\.end) == ["2026-10-30T04:00:00+05:30", "2026-10-30T05:00:00+05:30"])
        #expect(try s.events("day.started").count == 2)
        let yesterday = try s.journal.dayView(LocalDate("2026-10-29")!)
        #expect(yesterday.day.lastActivity == "2026-10-30T04:00:00+05:30")
        let today = try s.journal.dayView(LocalDate("2026-10-30")!)
        #expect(today.day.firstActivity == "2026-10-30T04:00:00+05:30")
    }

    @Test func yesterdaysPieceIsWrittenAsSoonAsTheBoundaryPasses() throws {
        let s = try setup(at: Self.at("2026-10-30", 3, 0))
        let engine = s.engine()
        try active(engine, s, from: Self.at("2026-10-30", 3, 0), to: Self.at("2026-10-30", 4, 0, 30))
        // The span is still open, but the day before already has its last activity.
        #expect(engine.machine.isOpen)
        #expect(try s.spans().map(\.end) == ["2026-10-30T04:00:00+05:30"])
    }

    @Test func sleepAndWakeWriteTwoSpans() throws {
        let s = try setup()
        let engine = s.engine()
        try active(engine, s, from: Self.at("2026-10-29", 9, 0), to: Self.at("2026-10-29", 10, 0))
        try send(engine, s, .sleep, at: Self.at("2026-10-29", 10, 1))
        try send(engine, s, .wake, at: Self.at("2026-10-29", 11, 0))
        try active(engine, s, from: Self.at("2026-10-29", 11, 0, 30), to: Self.at("2026-10-29", 12, 0))
        try send(engine, s, .sleep, at: Self.at("2026-10-29", 12, 0, 30))
        let spans = try s.spans()
        #expect(spans.map(\.start) == ["2026-10-29T09:00:00+05:30", "2026-10-29T11:00:30+05:30"])
        #expect(spans.map(\.end) == ["2026-10-29T10:01:00+05:30", "2026-10-29T12:00:30+05:30"])
        #expect(spans.map(\.source) == ["input", "wake"])
        #expect(try s.events("day.started").count == 1)
    }

    // MARK: - Never twice

    @Test func replayingTheSameStreamWritesNothing() throws {
        let s = try setup()
        func stream(_ engine: PresenceEngine) throws {
            try active(engine, s, from: Self.at("2026-10-29", 9, 0), to: Self.at("2026-10-29", 10, 0))
            try send(engine, s, .lock, at: Self.at("2026-10-29", 13, 0))
            try send(engine, s, .unlock, at: Self.at("2026-10-29", 14, 0))
            try active(engine, s, from: Self.at("2026-10-29", 14, 0, 10), to: Self.at("2026-10-29", 15, 0))
            try send(engine, s, .sample(idleSeconds: 300, unlocked: true), at: Self.at("2026-10-29", 15, 5))
        }
        try stream(s.engine())
        let events = try s.store.eventCount()
        let spans = try s.spans().count
        try stream(s.engine())
        #expect(try s.store.eventCount() == events)
        #expect(try s.spans().count == spans)
        #expect(spans == 2)
    }

    @Test func observedPresenceFillsOnlyWhatABackfillLeftOpen() throws {
        let s = try setup(at: Self.at("2026-10-29", 13, 0))
        let day = LocalDate("2026-10-29")!
        let backfill = PowerLogSpan(day: day, start: Self.at("2026-10-29", 9, 0), end: Self.at("2026-10-29", 12, 0))
        _ = try s.journal.backfillPresence(spans: [backfill])
        let engine = s.engine()
        try active(engine, s, from: Self.at("2026-10-29", 11, 0), to: Self.at("2026-10-29", 13, 0))
        try send(engine, s, .lock, at: Self.at("2026-10-29", 13, 0, 30))
        let spans = try s.spans()
        #expect(spans.map(\.source) == ["powerlog", "input"])
        #expect(spans.last?.start == "2026-10-29T12:00:00+05:30")
        #expect(spans.last?.end == "2026-10-29T13:00:30+05:30")
    }

    @Test func aDayAlreadyStartedIsNotStartedAgain() throws {
        let s = try setup(at: Self.at("2026-10-29", 8, 45))
        try s.journal.startDay(nil, at: "08:30", actor: .cli)
        let engine = s.engine()
        try active(engine, s, from: Self.at("2026-10-29", 9, 0), to: Self.at("2026-10-29", 9, 10))
        #expect(try s.events("day.started").count == 1)
        #expect(try s.journal.dayView(LocalDate("2026-10-29")!).day.firstActivity == "2026-10-29T08:30:00+05:30")
    }

    @Test func aWriteThatFailsLeavesTheMachineWhereItWas() throws {
        let s = try setup()
        let engine = s.engine()
        try active(engine, s, from: Self.at("2026-10-29", 9, 0), to: Self.at("2026-10-29", 9, 10))
        let before = engine.machine
        try s.store.db.run("CREATE TRIGGER no_spans BEFORE INSERT ON presence_spans BEGIN SELECT RAISE(ABORT, 'nope'); END")
        #expect(throws: CadenceError.self) { try send(engine, s, .lock, at: Self.at("2026-10-29", 9, 11)) }
        #expect(engine.machine == before)
    }

    // MARK: - Clocks and zones

    @Test func aBackwardJumpDoesNotWriteTimeTwice() throws {
        let s = try setup()
        let engine = s.engine()
        try active(engine, s, from: Self.at("2026-10-29", 9, 0), to: Self.at("2026-10-29", 10, 0))
        // The clock is set back 40 minutes and work goes on.
        try active(engine, s, from: Self.at("2026-10-29", 9, 20), to: Self.at("2026-10-29", 10, 30))
        try send(engine, s, .lock, at: Self.at("2026-10-29", 10, 31))
        let spans = try s.spans()
        // What was recorded before the jump is kept only up to the corrected clock; the rest is not written twice.
        #expect(spans.map(\.start) == ["2026-10-29T09:00:00+05:30", "2026-10-29T09:20:00+05:30"])
        #expect(spans.map(\.end) == ["2026-10-29T09:20:00+05:30", "2026-10-29T10:31:00+05:30"])
    }

    @Test func aBackwardJumpNeverWritesTheFuture() throws {
        let s = try setup()
        let engine = s.engine()
        try active(engine, s, from: Self.at("2026-10-29", 9, 0), to: Self.at("2026-10-29", 10, 0))
        try send(engine, s, .sample(idleSeconds: 0, unlocked: true), at: Self.at("2026-10-29", 9, 30))
        #expect(try s.spans().map(\.end) == ["2026-10-29T09:30:00+05:30"])
    }

    @Test func aForwardJumpLeavesTheMissingTimeUnknown() throws {
        let s = try setup()
        let engine = s.engine()
        try active(engine, s, from: Self.at("2026-10-29", 9, 0), to: Self.at("2026-10-29", 10, 0))
        try active(engine, s, from: Self.at("2026-10-29", 13, 0), to: Self.at("2026-10-29", 13, 30))
        try send(engine, s, .lock, at: Self.at("2026-10-29", 13, 31))
        let spans = try s.spans()
        #expect(spans.map(\.start) == ["2026-10-29T09:00:00+05:30", "2026-10-29T13:00:00+05:30"])
        #expect(spans.map(\.end) == ["2026-10-29T10:00:00+05:30", "2026-10-29T13:31:00+05:30"])
    }

    @Test func aZoneChangeMidDayKeepsTheDayInItsOwnZone() throws {
        let s = try setup()
        let first = s.engine()
        try active(first, s, from: Self.at("2026-10-29", 9, 0), to: Self.at("2026-10-29", 10, 0))
        try send(first, s, .lock, at: Self.at("2026-10-29", 10, 1))

        // The profile moves to London; the app opens a new journal and restores the engine.
        let london = try s.journal(timezone: "Europe/London")
        let engine = PresenceEngine(journal: london, clock: s.clock, restoring: first.machine)
        try send(engine, s, .unlock, at: Self.at("2026-10-29", 15, 0))
        // 15:30 to 17:30 in Kolkata is 10:00 to 12:00 in London, still 29 October either way.
        try active(engine, s, from: Self.at("2026-10-29", 15, 30), to: Self.at("2026-10-29", 17, 30), step: 60)
        try send(engine, s, .lock, at: Self.at("2026-10-29", 17, 31))
        // 03:00 to 05:00 in Kolkata is 21:30 to 23:30 in London. The 29th ends at 04:00 in Kolkata, but it is still the
        // 29th in London and the 30th has no row, so the rest stays on the 29th, read in London, and no 30th appears.
        try send(engine, s, .unlock, at: Self.at("2026-10-30", 3, 0))
        try active(engine, s, from: Self.at("2026-10-30", 3, 0), to: Self.at("2026-10-30", 5, 0), step: 60)
        try send(engine, s, .lock, at: Self.at("2026-10-30", 5, 1))

        let spans = try s.spans()  // Ordered as text, so the London piece sorts before 03:00 in Kolkata.
        #expect(Set(spans.map(\.day)) == ["2026-10-29"])
        #expect(
            spans.map(\.start) == [
                "2026-10-29T09:00:00+05:30", "2026-10-29T15:30:00+05:30", "2026-10-29T22:30:00+00:00",
                "2026-10-30T03:00:00+05:30",
            ])
        #expect(spans[3].end == "2026-10-30T04:00:00+05:30")
        let day = try london.dayView(LocalDate("2026-10-29")!).day
        #expect(day.tz == Self.zoneID)
        #expect(try s.events("day.started").count == 1)
    }

    @Test func aMoveWestDoesNotCarryTheOldZoneOntoLaterDays() throws {
        let s = try setup(at: Self.at("2026-10-28", 9, 0))
        let first = s.engine()
        try active(first, s, from: Self.at("2026-10-28", 9, 0), to: Self.at("2026-10-28", 10, 0))
        try send(first, s, .lock, at: Self.at("2026-10-28", 10, 1))

        let west = try s.journal(timezone: "America/Los_Angeles")
        let engine = PresenceEngine(journal: west, clock: s.clock, restoring: first.machine)
        // 15:45 on the 28th in Los Angeles is 04:15 on the 29th in Kolkata: the 29th has no row, so it does not start here.
        try send(engine, s, .unlock, at: Self.at("2026-10-29", 4, 15))
        try active(engine, s, from: Self.at("2026-10-29", 4, 15), to: Self.at("2026-10-29", 4, 30), step: 60)
        try send(engine, s, .sleep, at: Self.at("2026-10-29", 4, 31))
        // 09:00 to 17:00 on the 29th in Los Angeles (UTC-7) is 21:30 to 05:30 in Kolkata.
        try send(engine, s, .wake, at: Self.at("2026-10-29", 21, 29))
        try active(engine, s, from: Self.at("2026-10-29", 21, 30), to: Self.at("2026-10-30", 5, 30), step: 60)
        try send(engine, s, .lock, at: Self.at("2026-10-30", 5, 31))

        let onThe29th = try s.spans().filter { $0.day == "2026-10-29" }
        #expect(onThe29th.count == 1)
        #expect(onThe29th.first?.start == "2026-10-29T09:00:00-07:00")
        #expect(onThe29th.first?.end == "2026-10-29T17:01:00-07:00")
        #expect(try west.dayView(LocalDate("2026-10-29")!).day.tz == "America/Los_Angeles")
        #expect(try s.spans().allSatisfy { $0.day <= "2026-10-29" })
    }

    @Test func aSleepJustAfterTheBoundaryPutsNothingOnTheNewDay() throws {
        let s = try setup(at: Self.at("2026-10-30", 3, 0))
        let engine = s.engine()
        try active(engine, s, from: Self.at("2026-10-30", 3, 0), to: Self.at("2026-10-30", 3, 59))
        try send(engine, s, .sample(idleSeconds: 180, unlocked: true), at: Self.at("2026-10-30", 4, 2))
        try send(engine, s, .sleep, at: Self.at("2026-10-30", 4, 3))
        let spans = try s.spans()
        #expect(spans.map(\.day) == ["2026-10-29"])
        #expect(spans.last?.end == "2026-10-30T04:00:00+05:30")
        #expect(try s.journal.dayView(LocalDate("2026-10-30")!).day.firstActivity == nil)
    }

    @Test func theNewDayStartsAtItsFirstInputNotAtTheBoundary() throws {
        let s = try setup(at: Self.at("2026-10-30", 3, 0))
        let engine = s.engine()
        try active(engine, s, from: Self.at("2026-10-30", 3, 0), to: Self.at("2026-10-30", 3, 58))
        try active(engine, s, from: Self.at("2026-10-30", 4, 2), to: Self.at("2026-10-30", 4, 30))
        try send(engine, s, .lock, at: Self.at("2026-10-30", 4, 31))
        let spans = try s.spans()
        #expect(spans.map(\.day) == ["2026-10-29", "2026-10-30"])
        #expect(spans.last?.start == "2026-10-30T04:02:00+05:30")
        #expect(try s.journal.dayView(LocalDate("2026-10-30")!).day.firstActivity == "2026-10-30T04:02:00+05:30")
    }

    @Test func aSpanUnderAMinuteStillMovesTheLastActivity() throws {
        let s = try setup()
        let engine = s.engine()
        try active(engine, s, from: Self.at("2026-10-29", 9, 0), to: Self.at("2026-10-29", 10, 0))
        try send(engine, s, .lock, at: Self.at("2026-10-29", 10, 1))
        try send(engine, s, .unlock, at: Self.at("2026-10-29", 22, 0))
        try send(engine, s, .sample(idleSeconds: 0, unlocked: true), at: Self.at("2026-10-29", 22, 0, 10))
        try send(engine, s, .sleep, at: Self.at("2026-10-29", 22, 0, 50))
        #expect(try s.spans().last?.end == "2026-10-29T22:00:50+05:30")
        #expect(try s.journal.dayView(LocalDate("2026-10-29")!).day.lastActivity == "2026-10-29T22:00:50+05:30")
    }

    @Test func aManualStartLaterThanTheSpanStands() throws {
        let s = try setup()
        let engine = s.engine()
        try active(engine, s, from: Self.at("2026-10-29", 9, 0), to: Self.at("2026-10-29", 10, 0))
        try s.journal.startDay(nil, at: "09:45", actor: .cli)
        let corrected = try s.journal.dayView(LocalDate("2026-10-29")!).day.firstActivity
        try send(engine, s, .lock, at: Self.at("2026-10-29", 10, 1))
        #expect(try s.journal.dayView(LocalDate("2026-10-29")!).day.firstActivity == corrected)
    }

    @Test func aRetriedEventKeepsItsOwnTime() throws {
        let s = try setup()
        let engine = s.engine()
        try active(engine, s, from: Self.at("2026-10-29", 9, 0), to: Self.at("2026-10-29", 10, 0))
        s.clock.set(Self.at("2026-10-29", 10, 4))
        try engine.handle(.lock, at: Self.at("2026-10-29", 10, 0, 30))
        #expect(try s.spans().last?.end == "2026-10-29T10:00:30+05:30")
    }

    @Test func aBackfillAfterObservedPresenceAddsOnlyTheEdges() throws {
        let s = try setup()
        let engine = s.engine()
        try active(engine, s, from: Self.at("2026-10-29", 9, 0), to: Self.at("2026-10-29", 12, 0))
        try send(engine, s, .lock, at: Self.at("2026-10-29", 12, 1))
        s.clock.set(Self.at("2026-10-29", 13, 0))
        let span = PowerLogSpan(day: LocalDate("2026-10-29")!, start: Self.at("2026-10-29", 8, 58), end: Self.at("2026-10-29", 12, 5))
        #expect(try s.journal.backfillPresence(spans: [span]).written == 2)
        #expect(try s.journal.backfillPresence(spans: [span]) == PresenceBackfillResult(written: 0, skipped: 1))
        #expect(try s.spans().map(\.start) == ["2026-10-29T08:58:00+05:30", "2026-10-29T09:00:00+05:30", "2026-10-29T12:01:00+05:30"])
    }

    @Test func aDayStartIsNotWrittenWhenTheDayAlreadyHasActivity() throws {
        let s = try setup(at: Self.at("2026-10-29", 13, 0))
        let span = PowerLogSpan(day: LocalDate("2026-10-29")!, start: Self.at("2026-10-29", 9, 0), end: Self.at("2026-10-29", 12, 0))
        _ = try s.journal.backfillPresence(spans: [span])
        let engine = s.engine()
        try send(engine, s, .sample(idleSeconds: 0, unlocked: true), at: Self.at("2026-10-29", 13, 0))
        #expect(try s.events("day.started").isEmpty)
    }

    @Test func aNewDayAfterAZoneChangeTakesTheNewZone() throws {
        let s = try setup()
        let first = s.engine()
        try active(first, s, from: Self.at("2026-10-29", 9, 0), to: Self.at("2026-10-29", 10, 0))
        try send(first, s, .sleep, at: Self.at("2026-10-29", 10, 1))
        let london = try s.journal(timezone: "Europe/London")
        let engine = PresenceEngine(journal: london, clock: s.clock, restoring: first.machine)
        let zone = TimeZone(identifier: "Europe/London")!
        let nine = Timestamp.resolve(LocalDate("2026-10-31")!, hour: 9, minute: 0, in: zone)
        try send(engine, s, .wake, at: nine)
        try active(engine, s, from: nine, to: nine.addingTimeInterval(1800))
        try send(engine, s, .sleep, at: nine.addingTimeInterval(1860))
        let day = try london.dayView(LocalDate("2026-10-31")!).day
        #expect(day.tz == "Europe/London")
        #expect(day.firstActivity == "2026-10-31T09:00:00+00:00")
        #expect(day.lastActivity == "2026-10-31T09:31:00+00:00")
    }
}
