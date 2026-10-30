import Foundation
import Testing

@testable import CadenceCore

@Suite struct DemoSeedTests {
    static let start = Timestamp.parse(DemoSeed.startInstant)!
    static let proofAt = Timestamp.parse("2026-10-30T03:42:00Z")!

    /// A fresh store with the October demo written into it.
    static func seeded() throws -> (store: SQLiteStore, journal: Journal, clock: ManualClock) {
        let clock = ManualClock(start)
        let store = try TestStore.make(clock: clock, projector: LedgerProjector())
        let ids = ULIDGenerator(clock: clock, random: SeededRandomSource(seed: 1))
        let journal = try Journal(store: store, config: DemoSeed.config(), clock: clock, ids: ids)
        try DemoSeed.seed(into: journal, clock: clock)
        return (store, journal, clock)
    }

    static func october() -> ProofRequest {
        ProofRequest(
            from: LocalDate("2026-10-01")!, to: LocalDate("2026-10-29")!, zone: DemoSeed.timezone,
            name: DemoSeed.profileName, role: DemoSeed.profileRole, rules: DayRules(), generatedAt: proofAt)
    }

    static func rows(_ store: SQLiteStore, _ sql: String) throws -> [SQLRow] {
        try store.db.query(sql)
    }

    @Test func theOctoberProofMatchesTheSpec() throws {
        let (store, _, _) = try Self.seeded()
        let proof = try ProofExporter.export(store, Self.october())
        let root = proof.json.objectValue!
        let summary = root["summary"]!.objectValue!

        #expect(summary["sealed_workdays"]?.objectValue?["value"] == 19)
        #expect(summary["sealed_workdays"]?.objectValue?["of"] == 19)
        #expect(summary["sealed_workdays"]?.objectValue?["before_ledger"] == 0)

        // Spec 12.1: 61 of 73. A task open at wrap-up is moved and leaves "of", so 61 done, 9 slipped and
        // 3 dropped make 73; the ledger holds 78 planned tasks in all (73 counted plus 5 moved).
        #expect(summary["plan_done"]?.objectValue?["value"] == 61)
        #expect(summary["plan_done"]?.objectValue?["of"] == 73)
        let planAdded = root["chain"]!.objectValue!["events"]!.arrayValue!.filter { $0.objectValue?["type"] == "plan.added" }
        #expect(planAdded.count == 78)

        #expect(summary["merged_prs"]?.objectValue?["value"] == 14)
        #expect(summary["merged_prs"]?.objectValue?["assigned"] == 11)
        #expect(summary["merged_prs"]?.objectValue?["self_initiated"] == 3)
        #expect(summary["reviews"]?.objectValue?["value"] == 47)
        #expect(summary["ai_days"]?.objectValue?["value"] == 17)
        #expect(summary["ai_days"]?.objectValue?["of"] == 19)

        let items = root["days"]!.arrayValue!.flatMap { $0.objectValue!["items"]!.arrayValue! }
        let merged = items.filter { $0.objectValue?["kind"] == "pr.merged" }
        #expect(merged.count == 14)
        #expect(merged.allSatisfy { $0.objectValue?["origin"] == "collected" && $0.objectValue?["source"] == "github" })

        let python = try ProofExportTests.python(try ProofExportTests.write(proof.bytes))
        #expect(python.status == 0, "\(python.output)")
        #expect(python.output.contains("RESULT  PASS: the chain is complete"))
    }

    @Test func weekFortyFourReadsAsTheSpecSays() throws {
        let (store, journal, _) = try Self.seeded()
        let week = try journal.summary(from: LocalDate("2026-10-26")!, to: LocalDate("2026-10-29")!)
        #expect(week.mergedPRs == 4)
        #expect(week.reviews == 12)
        #expect(week.planDone == 14)
        #expect(week.planTotal == 18)
        #expect(week.slipsByReason == ["reprioritised": 2, "blocked": 1])
        #expect(week.aiDays == 4)
        #expect(week.aiCountedDays == 4)
        #expect(week.aiSessions == 19)

        var counts: [String: Int64] = [:]
        for row in try Self.rows(
            store, "SELECT kind, COUNT(*) AS n FROM entries WHERE day >= '2026-10-26' AND day <= '2026-10-29' AND status = 'accepted' GROUP BY kind")
        {
            counts[row.text("kind") ?? ""] = row.int("n")
        }
        #expect(counts["discussion.raised"] == 3)
        #expect(counts["meeting.led"] == 2)
        #expect(counts["decision.challenged"] == 1)
        #expect(counts["mentoring"] == 2)
        #expect(counts["incident.handled"] == 1)

        let onCall = try Self.rows(store, "SELECT date FROM days WHERE on_call = 1 ORDER BY date").compactMap { $0.text("date") }
        #expect(onCall == ["2026-10-27", "2026-10-28"])
        let dropped = try Self.rows(
            store, "SELECT COUNT(*) AS n FROM plan_tasks WHERE day >= '2026-10-26' AND day <= '2026-10-29' AND status = 'dropped'")
        #expect(dropped.first?.int("n") == 1)
    }

    @Test func theCalendarHasTwoDeclaredDays() throws {
        let (store, _, _) = try Self.seeded()
        let kinds = try Self.rows(store, "SELECT date, kind FROM days WHERE date IN ('2026-10-02', '2026-10-23') ORDER BY date")
        #expect(kinds.map { $0.text("kind") } == ["holiday", "leave_planned"])
    }

    @Test func everyWorkdaySealsInsideItsWindowAtAnEveningHour() throws {
        let (store, _, _) = try Self.seeded()
        let zone = TimeZone(identifier: DemoSeed.timezone)!
        let sealed = try Self.rows(store, "SELECT date, sealed_at FROM days WHERE sealed_at IS NOT NULL ORDER BY date")
        #expect(sealed.count == 19)
        for row in sealed {
            let at = Timestamp.parse(row.text("sealed_at") ?? "")!
            let clock = Timestamp.clockTime(at, in: zone)
            #expect(clock >= "17:20" && clock <= "18:30", "\(row.text("date") ?? "") sealed at \(clock)")
        }
    }

    @Test func seedingTwiceGivesTheSameLedgerAndTheSameProof() throws {
        let (a, _, _) = try Self.seeded()
        let (b, _, _) = try Self.seeded()
        #expect(try a.projectionDump() == b.projectionDump())
        #expect(try a.eventCount() == b.eventCount())
        let first = try ProofExporter.export(a, Self.october())
        let second = try ProofExporter.export(b, Self.october())
        #expect(first.bytes == second.bytes)
    }

    @Test func aStoreWithEventsIsRefused() throws {
        let clock = ManualClock(Self.start)
        let store = try TestStore.make(clock: clock, projector: LedgerProjector())
        let journal = try Journal(
            store: store, config: DemoSeed.config(), clock: clock, ids: ULIDGenerator(clock: clock, random: SeededRandomSource(seed: 1)))
        _ = try journal.log(LogRequest(text: "Already here"), actor: .cli, origin: .selfReported)
        do {
            try DemoSeed.seed(into: journal, clock: clock)
            Issue.record("seeding a non-empty store should be refused")
        } catch {
            #expect((error as? CadenceError)?.exitCode == 2)
        }
    }
}
