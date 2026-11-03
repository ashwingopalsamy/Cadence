import Foundation
import Testing

@testable import CadenceCore

@Suite struct PresenceBackfillTests {
    static let zoneID = "Asia/Kolkata"
    let zone = TimeZone(identifier: zoneID)!

    var now: Date { Timestamp.resolve(LocalDate("2026-10-30")!, hour: 12, minute: 0, in: zone) }

    func journal() throws -> (Journal, SQLiteStore) {
        let store = try TestStore.make(clock: ManualClock(now), projector: LedgerProjector())
        let journal = try Journal(
            store: store, config: Config.defaults(timezone: Self.zoneID), clock: ManualClock(now), ids: CountingIDs())
        return (journal, store)
    }

    func spans(_ name: String) throws -> [PowerLogSpan] {
        let parser = PowerLogParser(zone: zone, boundary: .standard)
        return parser.parse(try PowerLogTests.fixture(name), now: now).spans
    }

    func rowCount(_ store: SQLiteStore) throws -> Int {
        try store.db.query("SELECT COUNT(*) AS n FROM presence_spans").first?.int("n").map(Int.init) ?? -1
    }

    @Test func writesPowerlogSpansAndDerivesActivity() throws {
        let (journal, store) = try journal()
        let result = try journal.backfillPresence(spans: spans("normal-day.log"))
        #expect(result.written == 2)
        #expect(result.skipped == 0)
        #expect(try rowCount(store) == 2)
        let view = try journal.dayView(LocalDate("2026-10-27")!)
        #expect(view.presence.map(\.source) == [.powerlog, .powerlog])
        #expect(view.day.firstActivity == "2026-10-27T09:05:12+05:30")
        #expect(view.day.lastActivity == "2026-10-27T18:20:09+05:30")
        let events = try store.events(subject: "day:2026-10-27")
        #expect(events.allSatisfy { $0.type == "presence.span" })
        #expect(events.allSatisfy { $0.actor == .cli })
    }

    @Test func secondRunWritesNothing() throws {
        let (journal, store) = try journal()
        let input = try spans("overnight.log")
        let first = try journal.backfillPresence(spans: input)
        let events = try store.eventCount()
        let second = try journal.backfillPresence(spans: input)
        #expect(first.written == 3)
        #expect(second.written == 0)
        #expect(second.skipped == 3)
        #expect(try store.eventCount() == events)
        #expect(try rowCount(store) == 3)
    }

    @Test func duplicatesInOneBatchAreWrittenOnce() throws {
        let (journal, store) = try journal()
        let input = try spans("normal-day.log")
        let result = try journal.backfillPresence(spans: input + input)
        #expect(result.written == 2)
        #expect(result.skipped == 2)
        #expect(try rowCount(store) == 2)
    }

    @Test func futureDaysAreRefusedAndNothingIsWritten() throws {
        let (journal, store) = try journal()
        var input = try spans("normal-day.log")
        let later = Timestamp.resolve(LocalDate("2026-10-31")!, hour: 9, minute: 0, in: zone)
        input.append(PowerLogSpan(day: LocalDate("2026-10-31")!, start: later, end: later.addingTimeInterval(3600)))
        #expect(throws: CadenceError.self) { _ = try journal.backfillPresence(spans: input) }
        #expect(try rowCount(store) == 0)
    }

    @Test func spanEndingInTheFutureIsRefused() throws {
        let (journal, _) = try journal()
        let start = Timestamp.resolve(LocalDate("2026-10-30")!, hour: 11, minute: 0, in: zone)
        let span = PowerLogSpan(day: LocalDate("2026-10-30")!, start: start, end: start.addingTimeInterval(7200))
        #expect(throws: CadenceError.self) { _ = try journal.backfillPresence(spans: [span]) }
    }

    @Test func emptyInputWritesNothing() throws {
        let (journal, store) = try journal()
        let before = try store.eventCount()
        let result = try journal.backfillPresence(spans: [])
        #expect(result.written == 0)
        #expect(try store.eventCount() == before)
    }
}
