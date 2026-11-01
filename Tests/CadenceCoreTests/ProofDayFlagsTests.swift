import Foundation
import Testing

@testable import CadenceCore

/// A leave or holiday declared after its grace window is flagged on the day in the proof (docs/SPEC.md sections 3
/// and 12.1, docs/PLAN.md T1.22). "Declared" is the recorded time of the `day.declared` event, the same clock the
/// seal and the grace window use, never the day it names.
@Suite struct ProofDayFlagsTests {
    typealias T = ProofExportTests

    /// Mon 26 Oct 2026 is the first day; the ledger begins at 09:30 that morning in Kolkata.
    static func store() throws -> (SQLiteStore, ManualClock) {
        let clock = ManualClock(Timestamp.parse("2026-10-26T04:00:00Z")!)
        let store = try TestStore.make(clock: clock, projector: LedgerProjector())
        try store.ensureGenesis(profile: ["name": "Sample Person", "timezone": .string(T.zone)])
        return (store, clock)
    }

    static func declare(
        _ store: SQLiteStore, _ clock: ManualClock, at instant: String, day: String, kind: DayKind, tz: String = T.zone
    ) throws {
        clock.set(Timestamp.parse(instant)!)
        try store.append([EventPayload.dayDeclared(DayDeclared(day: day, tz: tz, kind: kind)).draft(actor: .cli)])
    }

    static func export(_ store: SQLiteStore, generatedAt: String, from: String = "2026-10-26", to: String = "2026-10-31") throws -> ProofFile {
        try ProofExporter.export(
            store,
            ProofRequest(
                from: LocalDate(from)!, to: LocalDate(to)!, zone: T.zone, name: "Sample Person", role: "Software Engineer",
                rules: DayRules(), generatedAt: Timestamp.parse(generatedAt)!))
    }

    static func flags(_ proof: ProofFile) -> [String: Bool] {
        var found: [String: Bool] = [:]
        for day in proof.json.objectValue?["days"]?.arrayValue ?? [] {
            let object = day.objectValue ?? [:]
            if let date = object["date"]?.stringValue, let late = object["flags"]?.objectValue?["declared_late"]?.boolValue {
                found[date] = late
            }
        }
        return found
    }

    @Test func aLeaveOrHolidayDeclaredAfterItsGraceWindowIsFlaggedOnThatDay() throws {
        let (store, clock) = try Self.store()
        // Tue 27: declared on Wed 28 at 15:30, inside its window (which ends Wed 28 23:59:59 in Kolkata).
        try Self.declare(store, clock, at: "2026-10-28T10:00:00Z", day: "2026-10-27", kind: .leavePlanned)
        // Fri 30: declared two days ahead.
        try Self.declare(store, clock, at: "2026-10-28T11:00:00Z", day: "2026-10-30", kind: .holiday)
        // Mon 26: declared on Thu 29 at 09:30, after its window closed on Tue 27.
        try Self.declare(store, clock, at: "2026-10-29T04:00:00Z", day: "2026-10-26", kind: .holiday)
        // Wed 28: declared on Thu 29 at 10:00, inside its window.
        try Self.declare(store, clock, at: "2026-10-29T04:30:00Z", day: "2026-10-28", kind: .leaveUnplanned)
        let proof = try Self.export(store, generatedAt: "2026-10-30T04:00:00Z")
        let flags = Self.flags(proof)
        #expect(flags["2026-10-26"] == true)
        #expect(flags["2026-10-27"] == false)
        #expect(flags["2026-10-28"] == false)
        #expect(flags["2026-10-30"] == false)
        // An ordinary workday with nothing declared carries the flag too, set to false.
        #expect(flags["2026-10-29"] == false)
        // The kind is still what was declared: the flag adds to it and changes no count.
        let kinds = (proof.json.objectValue?["days"]?.arrayValue ?? []).compactMap { day -> (String, String)? in
            guard let date = day.objectValue?["date"]?.stringValue, let kind = day.objectValue?["kind"]?.stringValue else { return nil }
            return (date, kind)
        }
        #expect(kinds.first { $0.0 == "2026-10-26" }?.1 == "holiday")
        #expect(try T.python(try T.write(proof.bytes)).status == 0)
    }

    @Test func theWindowEndsAtTheLastMomentOfTheNextCalendarDayInTheDaysZone() throws {
        // Kolkata is UTC+5:30, so Tue 27's window ends at Wed 28 18:29:59.999Z.
        var (store, clock) = try Self.store()
        try Self.declare(store, clock, at: "2026-10-28T18:29:59.999Z", day: "2026-10-27", kind: .leavePlanned)
        #expect(Self.flags(try Self.export(store, generatedAt: "2026-10-30T04:00:00Z"))["2026-10-27"] == false)
        (store, clock) = try Self.store()
        try Self.declare(store, clock, at: "2026-10-28T18:30:00.000Z", day: "2026-10-27", kind: .leavePlanned)
        #expect(Self.flags(try Self.export(store, generatedAt: "2026-10-30T04:00:00Z"))["2026-10-27"] == true)

        // A day kept in New York (UTC-4 in October) has its window end at Wed 28 23:59:59 there, which is
        // Thu 29 03:59:59Z. A declaration at 02:00Z is on time there and would be late if Kolkata were used.
        (store, clock) = try Self.store()
        try Self.declare(store, clock, at: "2026-10-29T02:00:00Z", day: "2026-10-27", kind: .holiday, tz: "America/New_York")
        #expect(Self.flags(try Self.export(store, generatedAt: "2026-10-30T04:00:00Z"))["2026-10-27"] == false)
        (store, clock) = try Self.store()
        try Self.declare(store, clock, at: "2026-10-29T04:00:00Z", day: "2026-10-27", kind: .holiday, tz: "America/New_York")
        #expect(Self.flags(try Self.export(store, generatedAt: "2026-10-30T04:00:00Z"))["2026-10-27"] == true)
    }

    @Test func changingLeaveForAnotherLeaveLaterKeepsTheTimeTheDayLeftTheCount() throws {
        let (store, clock) = try Self.store()
        try Self.declare(store, clock, at: "2026-10-28T10:00:00Z", day: "2026-10-27", kind: .leavePlanned)
        // Weeks later the kind is corrected: the day was out of the count on time, so nothing is hidden.
        try Self.declare(store, clock, at: "2026-11-09T05:00:00Z", day: "2026-10-27", kind: .leaveUnplanned)
        #expect(Self.flags(try Self.export(store, generatedAt: "2026-11-10T04:00:00Z"))["2026-10-27"] == false)
    }

    @Test func aDayDeclaredBackToAWorkdayAndThenToLeaveIsJudgedFromTheLatestEntry() throws {
        let (store, clock) = try Self.store()
        try Self.declare(store, clock, at: "2026-10-28T10:00:00Z", day: "2026-10-27", kind: .leavePlanned)
        try Self.declare(store, clock, at: "2026-10-28T11:00:00Z", day: "2026-10-27", kind: .workday)
        #expect(Self.flags(try Self.export(store, generatedAt: "2026-10-30T04:00:00Z"))["2026-10-27"] == false)
        // Declared leave again after the window closed: now it is late, whatever happened before.
        try Self.declare(store, clock, at: "2026-11-02T05:00:00Z", day: "2026-10-27", kind: .leavePlanned)
        #expect(Self.flags(try Self.export(store, generatedAt: "2026-11-03T04:00:00Z"))["2026-10-27"] == true)
        // And back to a workday: no leave or holiday is left to flag.
        try Self.declare(store, clock, at: "2026-11-02T06:00:00Z", day: "2026-10-27", kind: .workday)
        #expect(Self.flags(try Self.export(store, generatedAt: "2026-11-03T04:00:00Z"))["2026-10-27"] == false)
    }

    @Test func aWeekendHolidayDeclaredLateHidesNothingAndIsNotFlagged() throws {
        let (store, clock) = try Self.store()
        try Self.declare(store, clock, at: "2026-11-05T05:00:00Z", day: "2026-10-31", kind: .holiday)
        let flags = Self.flags(try Self.export(store, generatedAt: "2026-11-06T04:00:00Z"))
        #expect(flags["2026-10-31"] == false)
    }

    @Test func aConfiguredWorkdayOnASaturdayIsFlaggedWhenItsLeaveComesLate() throws {
        let (store, clock) = try Self.store()
        try Self.declare(store, clock, at: "2026-11-05T05:00:00Z", day: "2026-10-31", kind: .leaveUnplanned)
        let rules = DayRules(workdays: [.mon, .tue, .wed, .thu, .fri, .sat])
        let proof = try ProofExporter.export(
            store,
            ProofRequest(
                from: LocalDate("2026-10-26")!, to: LocalDate("2026-10-31")!, zone: T.zone, rules: rules,
                generatedAt: Timestamp.parse("2026-11-06T04:00:00Z")!))
        #expect(Self.flags(proof)["2026-10-31"] == true)
    }

    @Test func theRulesAnswerTheSameQuestionOnTheirOwn() {
        let rules = DayRules()
        let kolkata = TimeZone(identifier: T.zone)!
        let tue = LocalDate("2026-10-27")!
        let end = rules.graceEnd(of: tue, in: kolkata)
        #expect(!rules.declaredLate(tue, at: end, in: kolkata))
        #expect(rules.declaredLate(tue, at: end.addingTimeInterval(0.001), in: kolkata))
        #expect(!rules.declaredLate(tue, at: end.addingTimeInterval(-86_400 * 5), in: kolkata))
        // A Saturday is not a workday by default, so a late declaration there is not late for any count.
        let sat = LocalDate("2026-10-31")!
        #expect(!rules.declaredLate(sat, at: rules.graceEnd(of: sat, in: kolkata).addingTimeInterval(86_400), in: kolkata))
    }

    @Test func theFlagIsVisibleInTheFileTheHowToVerifyTextNamesItAndTheVerifierStillPasses() throws {
        let (store, clock) = try Self.store()
        try Self.declare(store, clock, at: "2026-10-29T04:00:00Z", day: "2026-10-26", kind: .holiday)
        let proof = try Self.export(store, generatedAt: "2026-10-30T04:00:00Z")
        let text = String(decoding: proof.bytes, as: UTF8.self)
        #expect(text.contains("\"flags\":{\"declared_late\":true}"))
        #expect(ProofText.howToVerify.contains("declared_late"))
        let report = ProofVerifier.verify(bytes: proof.bytes)
        #expect(report.passed, "\(report.lines)")
        #expect(try T.python(try T.write(proof.bytes)).status == 0)
        // The same store and request give the same bytes.
        #expect(try Self.export(store, generatedAt: "2026-10-30T04:00:00Z").bytes == proof.bytes)
    }

    @Test func theDemoProofFlagsNoDayBecauseItsLeaveAndHolidayWereDeclaredAhead() throws {
        let (store, _, _) = try DemoSeedTests.seeded()
        let proof = try ProofExporter.export(store, DemoSeedTests.october())
        let flags = Self.flags(proof)
        #expect(flags["2026-10-02"] == false)
        #expect(flags["2026-10-23"] == false)
        #expect(flags.values.allSatisfy { !$0 })
    }
}
