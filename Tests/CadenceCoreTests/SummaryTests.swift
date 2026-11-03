import Foundation
import Testing

@testable import CadenceCore

@Suite struct SummaryTests {
    static let zone = ProofExportTests.zone

    /// The proof tests' October, read through a journal whose clock is Fri 30 Oct 08:30 local.
    static func journal() throws -> (Journal, SQLiteStore, ManualClock) {
        let (store, clock) = try ProofExportTests.october()
        let config = Config.defaults(timezone: zone)
        return (try Journal(store: store, config: config, clock: clock, ids: CountingIDs()), store, clock)
    }

    static func range(_ a: String, _ b: String) -> (LocalDate, LocalDate) { (LocalDate(a)!, LocalDate(b)!) }

    // MARK: ranges

    @Test func rangesResolveFromToday() throws {
        let today = LocalDate("2026-10-30")!  // a Friday
        #expect(SummaryRange.week.resolve(today: today, cycleStart: nil) == (LocalDate("2026-10-26")!, today))
        #expect(SummaryRange.month.resolve(today: today, cycleStart: nil) == (LocalDate("2026-10-01")!, today))
        #expect(SummaryRange.cycle.resolve(today: today, cycleStart: nil) == (LocalDate("2026-10-01")!, today))
        #expect(SummaryRange.cycle.resolve(today: LocalDate("2027-02-03")!, cycleStart: nil).from == LocalDate("2026-10-01")!)
        #expect(SummaryRange.cycle.resolve(today: today, cycleStart: LocalDate("2026-10-12")!).from == LocalDate("2026-10-12")!)
        // A start in the future is unusable.
        #expect(SummaryRange.cycle.resolve(today: today, cycleStart: LocalDate("2026-11-01")!).from == LocalDate("2026-10-01")!)
        let monday = LocalDate("2026-10-26")!
        #expect(SummaryRange.week.resolve(today: monday, cycleStart: nil).from == monday)
        let sunday = LocalDate("2026-11-01")!
        #expect(SummaryRange.week.resolve(today: sunday, cycleStart: nil).from == monday)
    }

    @Test func rangeTextParsesAndRejects() throws {
        #expect(try SummaryRange.parse("week") == .week)
        #expect(try SummaryRange.parse("2026-10-01..2026-10-15") == .custom(LocalDate("2026-10-01")!, LocalDate("2026-10-15")!))
        for bad in ["", "year", "2026-10-01", "2026-10-15..2026-10-01", "2026-13-01..2026-13-02", "a..b..c"] {
            #expect(throws: CadenceError.self) { try SummaryRange.parse(bad) }
        }
    }

    // MARK: metrics

    @Test func numbersMatchTheProofSummaryForTheSameRange() throws {
        let (journal, store, clock) = try Self.journal()
        let (from, to) = Self.range("2026-10-27", "2026-10-30")
        let summary = try journal.summary(from: from, to: to)
        let proof = try ProofExporter.export(store, ProofExportTests.request(clock)).json.objectValue!["summary"]!.objectValue!
        let mine = summary.json.objectValue!
        #expect(summary.sealedWorkdays == 2 && summary.countedWorkdays == 3)
        #expect(mine["sealed_workdays"]?["value"] == proof["sealed_workdays"]?["value"])
        #expect(mine["sealed_workdays"]?["of"] == proof["sealed_workdays"]?["of"])
        #expect(mine["sealed_workdays"]?["before_ledger"] == proof["sealed_workdays"]?["before_ledger"])
        #expect(mine["plan_done"]?["value"] == proof["plan_done"]?["value"])
        #expect(mine["plan_done"]?["of"] == proof["plan_done"]?["of"])
        #expect(mine["merged_prs"]?["value"] == proof["merged_prs"]?["value"])
        #expect(mine["merged_prs"]?["assigned"] == proof["merged_prs"]?["assigned"])
        #expect(mine["merged_prs"]?["self_initiated"] == 0)
        #expect(mine["reviews"]?["value"] == proof["reviews"]?["value"])
        #expect(mine["ai"]?["days"]?["value"] == proof["ai_days"]?["value"])
        #expect(mine["ai"]?["days"]?["of"] == proof["ai_days"]?["of"])
        #expect(summary.workdays == 4)
        #expect(summary.label == "2026-10-27..2026-10-30")
    }

    @Test func entriesCountPerFamilyAndIncludeExcludedOnes() throws {
        let (journal, _, _) = try Self.journal()
        let (from, to) = Self.range("2026-10-27", "2026-10-30")
        let summary = try journal.summary(from: from, to: to)
        // E1, E2, E3, E4 and E6: accepted, in range. E5 is deleted, E0 and E7 are outside.
        #expect(summary.entries == 5)
        let families = try #require(summary.entriesByFamily)
        #expect(families.values.reduce(0, +) == 5)
        #expect(families["review"] == 1)
        #expect(families["leadership"] == 0)
    }

    @Test func presenceSpreadIsAMedianOfClockTimes() throws {
        let (journal, _, _) = try Self.journal()
        let (from, to) = Self.range("2026-10-27", "2026-10-30")
        let summary = try journal.summary(from: from, to: to)
        #expect(summary.firstActivity == ClockSpread(median: "09:41", earliest: "09:41", latest: "09:41", days: 1))
        #expect(summary.lastActivity == nil)
    }

    @Test func weekendsAndDaysOffNeverMoveTheActivitySpreads() throws {
        let (journal, _, _) = try ActivityFixture.make()
        let (from, to) = Self.range("2026-10-05", "2026-10-25")
        let summary = try journal.summary(from: from, to: to)
        // Eight workdays have a start: Mon 5, 12 and 19, Tue 6 (read in New York) and 13, Wed 7, Thu 8 and Sat 17, which was
        // declared a workday. With the weekend and the leave and holiday days in, twelve days counted: the median read 09:00
        // and the earliest 04:30, a Sunday.
        #expect(summary.firstActivity == ClockSpread(median: "09:45", earliest: "09:00", latest: "12:00", days: 8))
        // Seven have an end: Thu 8 has none. The days off used to make it eleven days, a median of 18:00 and a latest of 23:30.
        #expect(summary.lastActivity == ClockSpread(median: "17:30", earliest: "14:00", latest: "19:00", days: 7))
    }

    @Test func aRangeOfOnlyDaysOffHasNoActivitySpread() throws {
        let (journal, _, _) = try ActivityFixture.make()
        // Sat 10 and Sun 11 (weekend), Wed 14 (leave) and Thu 15 (holiday) all have a start and an end.
        for (a, b) in [("2026-10-10", "2026-10-11"), ("2026-10-14", "2026-10-15")] {
            let (from, to) = Self.range(a, b)
            let summary = try journal.summary(from: from, to: to)
            #expect(summary.firstActivity == nil && summary.lastActivity == nil)
            #expect(summary.json.objectValue?["presence"]?["first_activity"] == .null)
        }
    }

    @Test func unknownIsNilAndNullNotZero() throws {
        let (journal, _, _) = try Self.journal()
        // Before the ledger began: nothing is known, and the workdays are not counted as unsealed.
        let (from, to) = Self.range("2026-10-05", "2026-10-09")
        let summary = try journal.summary(from: from, to: to)
        #expect(summary.workdays == 5 && summary.beforeLedger == 5)
        #expect(summary.sealedWorkdays == nil && summary.countedWorkdays == 0)
        #expect(summary.planDone == nil && summary.planTotal == nil && summary.slipsByReason == nil)
        #expect(summary.mergedPRs == nil && summary.reviews == nil && summary.entries == nil && summary.entriesByFamily == nil)
        #expect(summary.aiDays == nil && summary.aiSessions == nil && summary.outputTokens == nil)
        let json = summary.json.objectValue!
        #expect(json["sealed_workdays"]?["value"] == .null)
        #expect(json["plan_done"]?["value"] == .null)
        #expect(json["merged_prs"]?["value"] == .null)
        #expect(json["entries"]?["by_family"] == .null)
        #expect(json["presence"]?["first_activity"] == .null)
        #expect(json["ai"]?["output_tokens"]?["value"] == .null)
        #expect(json["findings"] == .array([]))
    }

    @Test func slipsGroupByReasonAndTokensTakeOneSourcePerDay() throws {
        let (journal, store, _) = try Self.journal()
        let day = LocalDate("2026-10-27")!  // unsealed and past its window: the 29th is sealed, and later tasks are left out
        let task = try journal.planAdd(title: "Draft design", day: day, estimateMin: nil, origin: .selfReported, actor: .cli)
        let other = try journal.planAdd(title: "Write ADR", day: day, estimateMin: nil, origin: .selfReported, actor: .cli)
        _ = try journal.planResolve(taskID: task.id, status: .slipped, reason: "reprioritised", note: nil, links: [], actor: .cli)
        _ = try journal.planResolve(taskID: other.id, status: .slipped, reason: "reprioritised", note: nil, links: [], actor: .cli)
        func usage(_ day: String, _ source: String, out: Int64?) -> EventDraft {
            EventPayload.genaiUsage(GenAIUsage(
                day: day, tool: "claude-code", model: "*", source: source, sessions: 1, requests: nil,
                tokens: TokenCounts(input: nil, output: out, cacheRead: nil, cacheWrite: nil), costMicros: nil,
                estimated: false)).draft(actor: .collector("claude-code"))
        }
        try store.append([
            usage("2026-10-27", "import", out: 500),
            usage("2026-10-29", "transcripts", out: 900), usage("2026-10-29", "endpoint", out: 1000),
            EventPayload.genaiSession(GenAISession(
                sessionId: "S1", tool: "claude-code", day: "2026-10-29", startedAt: "2026-10-29T10:00:00+05:30"))
                .draft(actor: .hook),
        ])
        let (from, to) = Self.range("2026-10-27", "2026-10-30")
        let summary = try journal.summary(from: from, to: to)
        #expect(summary.slipsByReason == ["reprioritised": 2])
        #expect(summary.outputTokens == 1500)  // import on the 27th, endpoint (not transcripts, not summed) on the 29th
        #expect(summary.tokenSources == ["import": 1, "endpoint": 1])
        #expect(summary.aiSessions == 1)
        #expect(summary.aiDays == 3 && summary.aiCountedDays == 3)  // usage rows on the 27th, 28th and 29th
    }

    @Test func slipsCountOnlyTasksOnCountedDays() throws {
        let (journal, _, _) = try Self.journal()
        func slip(_ day: String, _ reason: String) throws {
            let task = try journal.planAdd(title: "Task", day: LocalDate(day)!, estimateMin: nil, origin: .selfReported, actor: .cli)
            _ = try journal.planResolve(taskID: task.id, status: .slipped, reason: reason, note: nil, links: [], actor: .cli)
        }
        try slip("2026-10-27", "reprioritised")
        try slip("2026-10-30", "blocked")  // today: unsealed, grace still open, so the day is not counted yet
        let (from, to) = Self.range("2026-10-27", "2026-10-30")
        let summary = try journal.summary(from: from, to: to)
        #expect(summary.slipsByReason == ["reprioritised": 1])
        #expect(summary.planTotal == 3)  // T1, T2 on the 28th and the slipped task on the 27th
    }

    @Test func aUsageRowWithoutSessionsButWithTokensIsAIActivity() throws {
        let (journal, store, _) = try Self.journal()
        let (from, to) = Self.range("2026-10-27", "2026-10-30")
        let base = try journal.summary(from: from, to: to)
        try store.db.run(
            "INSERT INTO genai_usage (day, tool, model, source, sessions, tokens_out) VALUES (?, ?, ?, ?, NULL, ?)",
            [.text("2026-10-27"), .text("claude-code"), .text("*"), .text("endpoint"), .int(50)])
        try store.db.run(
            "INSERT INTO genai_usage (day, tool, model, source, sessions) VALUES (?, ?, ?, ?, NULL)",
            [.text("2026-10-26"), .text("claude-code"), .text("*"), .text("endpoint")])
        let summary = try journal.summary(from: from, to: to)
        #expect(summary.aiDays == (base.aiDays ?? 0) + 1)
        #expect(summary.aiCountedDays == base.aiCountedDays + 1)
    }

    @Test func aSummaryRefusesBadRanges() throws {
        let (journal, _, _) = try Self.journal()
        #expect(throws: CadenceError.self) { try journal.summary(from: LocalDate("2026-10-30")!, to: LocalDate("2026-10-01")!) }
        #expect(throws: CadenceError.self) { try journal.summary(from: LocalDate("2020-01-01")!, to: LocalDate("2026-10-01")!) }
    }

    @Test func summaryNeverWritesToTheLedger() throws {
        let (journal, store, _) = try Self.journal()
        let before = try store.eventCount()
        _ = try journal.summary(.week)
        #expect(try store.eventCount() == before)
    }

    @Test func weekIsMondayToTodayInTheProfileZone() throws {
        let (journal, _, _) = try Self.journal()
        let week = try journal.summary(.week)
        #expect(week.from == LocalDate("2026-10-26")! && week.to == LocalDate("2026-10-30")! && week.label == "week")
        #expect(week.zone == Self.zone)
        #expect(week.streak.current == 2)
    }

    // MARK: a ledger with no start

    /// A journal made only for reading over an empty store: no genesis event, so the ledger has no start.
    static func readingJournal() throws -> (Journal, SQLiteStore) {
        let clock = ManualClock(Timestamp.parse("2026-10-30T03:00:00Z")!)  // Fri 30 Oct 08:30 in Kolkata
        let store = try TestStore.make(clock: clock, projector: LedgerProjector())
        let journal = try Journal(
            store: store, config: Config.defaults(timezone: zone), clock: clock, ids: CountingIDs(), actor: .mcp, writesGenesis: false)
        return (journal, store)
    }

    @Test func withNoLedgerStartEveryWorkdayIsBeforeTheLedgerNotUnsealed() throws {
        let (journal, store) = try Self.readingJournal()
        #expect(try store.eventCount() == 0)
        // Past workdays must not read as "sealed 0 of 3 counted workdays".
        for (from, to, workdays) in [("2026-10-26", "2026-10-30", 5), ("2026-10-05", "2026-10-09", 5), ("2026-09-01", "2026-09-30", 22)] {
            let summary = try journal.summary(from: LocalDate(from)!, to: LocalDate(to)!)
            #expect(summary.workdays == workdays, "\(from)")
            #expect(summary.beforeLedger == workdays, "\(from)")
            #expect(summary.countedWorkdays == 0 && summary.sealedWorkdays == nil, "\(from)")
            #expect(summary.planDone == nil && summary.aiDays == nil, "\(from)")
            let json = summary.json.objectValue!
            #expect(json["sealed_workdays"]?["value"] == .null && json["sealed_workdays"]?["of"] == 0, "\(from)")
            #expect(json["sealed_workdays"]?["before_ledger"] == .int(Int64(workdays)), "\(from)")
            let text = SummaryRendering.human(summary)
            #expect(!text.contains("sealed 0 of"), "\(text)")
            #expect(text.contains("(\(workdays) before the ledger began)"), "\(text)")
            #expect(text.contains("No counted data in this range yet."), "\(text)")
        }
        let week = try journal.summary(.week)
        #expect(week.beforeLedger == week.workdays && week.countedWorkdays == 0)
        #expect(try store.eventCount() == 0)
    }

    @Test func aLedgerThatHasAStartStillCountsItsOwnWorkdays() throws {
        // The fix is for an empty ledger only: with a genesis event the October fixture counts as before.
        let (journal, _, _) = try Self.journal()
        let summary = try journal.summary(from: LocalDate("2026-10-27")!, to: LocalDate("2026-10-30")!)
        #expect(summary.countedWorkdays == 3 && summary.sealedWorkdays == 2)
    }
}
