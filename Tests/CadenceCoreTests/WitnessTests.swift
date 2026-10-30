import Foundation
import Testing

@testable import CadenceCore

@Suite struct WitnessTests {
    private func store() throws -> (SQLiteStore, ManualClock) {
        let clock = ManualClock(TestStore.start)
        let store = try TestStore.make(clock: clock, projector: LedgerProjector())
        try store.ensureGenesis(profile: ["timezone": "Asia/Kolkata"])
        return (store, clock)
    }

    private func note(_ store: SQLiteStore, day: String) throws {
        let payload = EventPayload.dayNoted(DayNoted(day: day, tz: "Asia/Kolkata", note: "x"))
        try store.append([payload.draft(actor: .cli)])
    }

    @Test func codeIsTheFirstSixteenHexOfTheCheckpointHash() throws {
        let (store, _) = try store()
        let witness = try store.witness(day: LocalDate("2026-10-29")!, actor: .app)
        let head = try #require(try store.head())
        #expect(witness.eventHash == head.hash)
        #expect(witness.code == String(head.hash.prefix(16)))
        #expect(witness.code.count == Witness.codeLength)
        #expect(head.type == "witness.checkpoint")
        #expect(head.subject == "day:2026-10-29")
        #expect(head.data == ["day": "2026-10-29", "purpose": "stand-up"])
        #expect(witness.line == "cadence \(witness.code)")
        #expect(witness.date == LocalDate("2026-10-29")!)
    }

    @Test func copyingAgainWithNothingNewReusesTheCheckpoint() throws {
        let (store, _) = try store()
        let day = LocalDate("2026-10-29")!
        let first = try store.witness(day: day, actor: .app)
        let second = try store.witness(day: day, actor: .app)
        #expect(first == second)
        #expect(try store.eventCount() == 2)
    }

    @Test func aNewEventOrAnotherDayMakesANewCheckpoint() throws {
        let (store, _) = try store()
        let day = LocalDate("2026-10-29")!
        let first = try store.witness(day: day, actor: .app)
        try note(store, day: "2026-10-29")
        let second = try store.witness(day: day, actor: .app)
        #expect(second.code != first.code)
        let third = try store.witness(day: LocalDate("2026-10-30")!, actor: .app)
        #expect(third.code != second.code)
        #expect(try store.eventCount() == 5)
        // Other purposes never reuse a stand-up checkpoint.
        let fourth = try store.witness(day: LocalDate("2026-10-30")!, purpose: "manual", actor: .cli)
        #expect(fourth.code != third.code)
    }

    @Test func witnessesListInOrderAndFilterByRange() throws {
        let (store, _) = try store()
        for d in ["2026-10-27", "2026-10-28", "2026-10-29"] {
            try note(store, day: d)
            _ = try store.witness(day: LocalDate(d)!, actor: .app)
        }
        let all = try store.witnesses()
        #expect(all.map(\.date.description) == ["2026-10-27", "2026-10-28", "2026-10-29"])
        let some = try store.witnesses(from: LocalDate("2026-10-28")!, through: LocalDate("2026-10-28")!)
        #expect(some.map(\.date.description) == ["2026-10-28"])
        #expect(some[0].where == "stand-up message")
    }

    @Test func findLocatesACodeAndRejectsBadInput() throws {
        let (store, _) = try store()
        let witness = try store.witness(day: LocalDate("2026-10-29")!, actor: .app)
        #expect(try store.find(witnessCode: witness.code)?.hash == witness.eventHash)
        #expect(try store.find(witnessCode: witness.code.uppercased())?.hash == witness.eventHash)
        #expect(try store.find(witnessCode: "cadence \(witness.code)")?.hash == witness.eventHash)
        #expect(try store.find(witnessCode: "0000000000000000") == nil)
        #expect(throws: CadenceError.self) { try store.find(witnessCode: "abc") }
        #expect(throws: CadenceError.self) { try store.find(witnessCode: "zzzzzzzzzzzzzzzz") }
        // A LIKE wildcard must not match anything.
        #expect(throws: CadenceError.self) { try store.find(witnessCode: "%%%%%%%%%%%%%%%%") }
    }

    @Test func purposeIsValidated() throws {
        let (store, _) = try store()
        #expect(throws: CadenceError.self) { try store.witness(day: LocalDate("2026-10-29")!, purpose: "", actor: .app) }
        #expect(throws: CadenceError.self) {
            try store.witness(day: LocalDate("2026-10-29")!, purpose: "Stand Up", actor: .app)
        }
    }

    @Test func aWitnessNeedsAGenesis() throws {
        let store = try TestStore.make()
        #expect(throws: CadenceError.self) { try store.witness(day: LocalDate("2026-10-29")!, actor: .app) }
    }
}
