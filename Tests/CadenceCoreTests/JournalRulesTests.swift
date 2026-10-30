import Foundation
import Testing

@testable import CadenceCore

/// Phase 1 audit rules for the journal: what a write may say about time, tasks and text.
@Suite struct JournalRulesTests {
    typealias Fixture = JournalTests.Fixture

    func validation(_ body: () throws -> Void) -> String? {
        do { try body() } catch let error as CadenceError {
            if case .validation(let message) = error { return message }
        } catch {}
        return nil
    }

    static func request(_ text: String, at: String? = nil, date: LocalDate? = nil) -> LogRequest {
        LogRequest(text: text, date: date, occurredAt: at)
    }

    // MARK: genesis actor

    @Test func genesisIsWrittenByTheCallersActor() throws {
        let clock = ManualClock(TestStore.start)
        let store = try TestStore.make(clock: clock, projector: LedgerProjector())
        _ = try Journal(
            store: store, config: Config.defaults(timezone: JournalTests.zoneID), clock: clock, ids: CountingIDs(),
            actor: .cli)
        let genesis = try #require(try store.events(after: 0, limit: 1).first)
        #expect(genesis.type == "ledger.genesis" && genesis.actor == .cli)
        let app = try Fixture()
        let first = try #require(try app.store.events(after: 0, limit: 1).first)
        #expect(first.actor == .app)
    }

    // MARK: planResolve

    @Test func aMovedTaskCannotBeResolved() throws {
        let f = try Fixture()
        let task = try f.journal.planAdd(title: "Leftover", day: nil, estimateMin: nil, origin: .selfReported, actor: .cli)
        let carried = try #require(try f.journal.seal(nil, actor: .cli).carried.first)
        let message = validation {
            _ = try f.journal.planResolve(taskID: task.id, status: .done, reason: nil, note: nil, links: [], actor: .cli)
        }
        #expect(message?.contains(carried.task.id) == true)
        #expect(try f.journal.task(task.id).status == .moved)
        // The carried task itself resolves normally.
        let done = try f.journal.planResolve(
            taskID: carried.task.id, status: .done, reason: nil, note: nil, links: [], actor: .cli)
        #expect(done.status == .done)
    }

    @Test func aResolvedTaskCanBeResolvedAgainBeforeAndAfterTheSeal() throws {
        let f = try Fixture()
        let task = try f.journal.planAdd(title: "Write the RFC", day: nil, estimateMin: nil, origin: .selfReported, actor: .cli)
        _ = try f.journal.planResolve(taskID: task.id, status: .done, reason: nil, note: nil, links: [], actor: .cli)
        let slipped = try f.journal.planResolve(
            taskID: task.id, status: .slipped, reason: "reprioritised", note: nil, links: [], actor: .cli)
        #expect(slipped.status == .slipped)
        _ = try f.journal.seal(nil, actor: .cli)
        let dropped = try f.journal.planResolve(taskID: task.id, status: .dropped, reason: nil, note: nil, links: [], actor: .cli)
        #expect(dropped.status == .dropped)
        let resolutions = try f.journal.history(subject: "task:\(task.id)").filter { $0.type == "plan.resolved" }
        #expect(resolutions.count == 3)
    }

    // MARK: log times

    @Test func logRefusesAFutureInstant() throws {
        let f = try Fixture()
        let before = try f.store.eventCount()
        #expect(
            validation { _ = try f.journal.log(Self.request("Did a thing", at: "2027-01-01T10:00:00Z"), actor: .cli, origin: .selfReported) }
                == "--at: 2027-01-01T10:00:00Z is in the future")
        #expect(
            validation { _ = try f.journal.log(Self.request("Did a thing", at: "23:30"), actor: .cli, origin: .selfReported) }
                == "--at: 23:30 is in the future")
        #expect(try f.store.eventCount() == before)
    }

    @Test func logRefusesAnInstantNotOnTheStatedDay() throws {
        let f = try Fixture()
        let day = LocalDate("2026-09-01")!
        let message = validation {
            _ = try f.journal.log(
                Self.request("Did a thing", at: "2026-09-20T10:00:00Z", date: day), actor: .cli, origin: .selfReported)
        }
        #expect(message == "--at: 2026-09-20T10:00:00Z is not on 2026-09-01")
    }

    @Test func logDerivesTheDayFromAnRFC3339Instant() throws {
        let f = try Fixture()
        let entry = try f.journal.log(
            Self.request("Did a thing", at: "2026-09-20T10:00:00Z"), actor: .cli, origin: .selfReported)
        #expect(entry.day == "2026-09-20")
        #expect(entry.occurredAt == "2026-09-20T15:30:00+05:30")
    }

    @Test func dayMarksRefuseFutureAndOffDayInstants() throws {
        let f = try Fixture()
        #expect(
            validation { try f.journal.startDay(nil, at: "23:30", actor: .cli) } == "--at: 23:30 is in the future")
        #expect(
            validation { try f.journal.endDay(nil, at: "2027-01-01T10:00:00Z", actor: .cli) }
                == "--at: 2027-01-01T10:00:00Z is in the future")
        #expect(
            validation { try f.journal.endDay(f.yesterday, at: "2026-09-21T10:00:00Z", actor: .cli) }
                == "--at: 2026-09-21T10:00:00Z is not on 2026-09-20")
        #expect(try f.store.eventCount() == 1)
        try f.journal.startDay(nil, at: "2026-09-20T10:00:00Z", actor: .cli)
        #expect(try f.journal.dayView(f.yesterday).day.firstActivity == "2026-09-20T15:30:00+05:30")
    }

    // MARK: day zone

    @Test func timesAreReadInTheDaysOwnZone() throws {
        let f = try DayMechanicsTests.Fixture()
        try f.journal.startDay(f.day("2026-10-29"), at: "09:00", actor: .cli)
        f.go("2026-10-29", 20, 0)
        // The profile moves to New York; 10-29 keeps its Kolkata zone.
        let moved = try Journal(
            store: f.store, config: Config.defaults(timezone: "America/New_York"), clock: f.clock, ids: CountingIDs())
        try moved.endDay(f.day("2026-10-29"), at: "19:00", actor: .cli)
        let view = try moved.dayView(f.day("2026-10-29"))
        #expect(view.day.lastActivity == "2026-10-29T19:00:00+05:30")
        let mark = try #require(try moved.history(subject: "day:2026-10-29").last)
        #expect(mark.data.objectValue?["tz"]?.stringValue == "Asia/Kolkata")

        let entry = try moved.log(
            LogRequest(text: "Reviewed the plan", date: f.day("2026-10-29"), occurredAt: "09:30"), actor: .cli,
            origin: .selfReported)
        #expect(entry.occurredAt == "2026-10-29T09:30:00+05:30")

        try moved.declare(f.day("2026-10-29"), kind: .holiday, label: nil, actor: .cli)
        let declared = try #require(try moved.history(subject: "day:2026-10-29").last)
        #expect(declared.data.objectValue?["tz"]?.stringValue == "Asia/Kolkata")
    }

    // MARK: clean text

    @Test func bidiFormatCharactersAreStripped() throws {
        let f = try Fixture()
        let tricks = "\u{202A}\u{202B}\u{202C}\u{202D}\u{202E}\u{2066}\u{2067}\u{2068}\u{2069}\u{200E}\u{200F}\u{061C}"
        let entry = try f.journal.log(
            LogRequest(text: "Fixed\(tricks) the build", note: "n\(tricks)ote"), actor: .cli, origin: .selfReported)
        #expect(entry.title == "Fixed the build")
        #expect(entry.attrs["note"] == .string("note"))
        let task = try f.journal.planAdd(
            title: "Plan\(tricks)ned", day: nil, estimateMin: nil, origin: .selfReported, actor: .cli)
        #expect(task.title == "Planned")
        let slipped = try f.journal.planResolve(
            taskID: task.id, status: .slipped, reason: "re\(tricks)prioritised", note: "no\(tricks)te", links: [], actor: .cli)
        #expect(slipped.reason == "reprioritised" && slipped.reasonNote == "note")
        try f.journal.declare(f.yesterday, kind: .holiday, label: "Holi\(tricks)day", actor: .cli)
        #expect(try f.journal.dayView(f.yesterday).day.label == "Holiday")
    }
}
