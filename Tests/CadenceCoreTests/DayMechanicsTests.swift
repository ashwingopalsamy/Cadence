import Foundation
import Testing

@testable import CadenceCore

@Suite struct DayMechanicsTests {
    static let zoneID = "Asia/Kolkata"

    /// A journal whose clock starts at 18:00 local on `start` and moves with `go`.
    struct Fixture {
        let clock: ManualClock
        let store: SQLiteStore
        let journal: Journal
        let zone = TimeZone(identifier: DayMechanicsTests.zoneID)!

        init(start: String = "2026-10-29", hour: Int = 18) throws {
            let zone = TimeZone(identifier: DayMechanicsTests.zoneID)!
            clock = ManualClock(Timestamp.resolve(LocalDate(start)!, hour: hour, minute: 0, in: zone))
            store = try TestStore.make(clock: clock, projector: LedgerProjector())
            journal = try Journal(
                store: store, config: Config.defaults(timezone: DayMechanicsTests.zoneID), clock: clock,
                ids: CountingIDs())
        }

        func go(_ day: String, _ hour: Int = 18, _ minute: Int = 0) {
            clock.set(Timestamp.resolve(LocalDate(day)!, hour: hour, minute: minute, in: zone))
        }

        func seal(_ day: String, at: (String, Int, Int)? = nil) throws -> SealResult {
            if let at { go(at.0, at.1, at.2) }
            return try journal.seal(LocalDate(day)!, actor: .cli)
        }

        func plan(_ title: String, on day: String) throws -> PlanTask {
            try journal.planAdd(title: title, day: LocalDate(day)!, estimateMin: nil, origin: .selfReported, actor: .cli)
        }

        func day(_ text: String) -> LocalDate { LocalDate(text)! }
    }

    func validationMessage(_ body: () throws -> Void) -> String? {
        do { try body() } catch let error as CadenceError {
            if case .validation(let message) = error { return message }
        } catch {}
        return nil
    }

    // MARK: seal

    @Test func sealTodayRecordsCountsPlanAndCarriesOpenTasks() throws {
        let f = try Fixture()
        _ = try f.journal.log(LogRequest(text: "Merged the retry budget", kind: .prMerged), actor: .cli, origin: .selfReported)
        _ = try f.journal.log(LogRequest(text: "Reviewed the RFC", kind: .docReviewed), actor: .cli, origin: .selfReported)
        _ = try f.journal.log(LogRequest(text: "Reviewed another RFC", kind: .docReviewed), actor: .cli, origin: .selfReported)
        let done = try f.plan("Write ADR", on: "2026-10-29")
        let slipped = try f.plan("Draft design", on: "2026-10-29")
        let dropped = try f.plan("Old idea", on: "2026-10-29")
        let open = try f.plan("Prototype replay ACME-000000", on: "2026-10-29")
        _ = try f.journal.planResolve(taskID: done.id, status: .done, reason: nil, note: nil, links: [], actor: .cli)
        _ = try f.journal.planResolve(taskID: slipped.id, status: .slipped, reason: "reprioritised", note: nil, links: [], actor: .cli)
        _ = try f.journal.planResolve(taskID: dropped.id, status: .dropped, reason: nil, note: nil, links: [], actor: .cli)

        let result = try f.journal.seal(nil, actor: .cli)
        #expect(result.day == f.day("2026-10-29"))
        #expect(result.counts)
        #expect(result.sealedAt == "2026-10-29T18:00:00+05:30")
        #expect(result.entryCounts == ["delivery": 1, "review": 2, "entries": 3])
        #expect(result.plan == PlanCounts(done: 1, slipped: 1, dropped: 1, moved: 1, open: 0))
        #expect(result.carried.count == 1)
        let carried = try #require(result.carried.first)
        #expect(carried.from == open.id)
        #expect(carried.task.day == "2026-10-30")
        #expect(carried.task.origin == .carried && carried.task.carriedFrom == open.id)
        #expect(carried.task.title == open.title && carried.task.ticket == open.ticket)
        #expect(carried.task.status == .open && carried.task.position == 1)
        #expect(carried.task.plannedAt == "2026-10-29T18:00:00+05:30")
        #expect(try f.journal.task(open.id).status == .moved)
        #expect(try f.journal.task(carried.task.id) == carried.task)
        #expect(try f.journal.dayView(f.day("2026-10-29")).day.sealedAt != nil)
        #expect(result.streak.current == 1)
    }

    @Test func sealHeadIsTheEventBeforeTheSeal() throws {
        let f = try Fixture()
        _ = try f.plan("Open task", on: "2026-10-29")
        _ = try f.journal.seal(nil, actor: .cli)
        let events = try f.store.events(subject: "day:2026-10-29")
        let seal = try #require(events.last)
        #expect(seal.type == "day.sealed")
        let before = try #require(try f.store.events(after: seal.seq - 2, limit: 1).first)
        #expect(before.type == "plan.added")
        #expect(seal.prev == before.hash)
        #expect(seal.data.objectValue?["head"]?.stringValue == before.hash)
        // The seal is its own append: nothing else follows it.
        #expect(try f.store.head()?.hash == seal.hash)
    }

    @Test func sealWithNothingToCarryStillSeals() throws {
        let f = try Fixture()
        let result = try f.journal.seal(nil, actor: .cli)
        #expect(result.carried.isEmpty && result.entryCounts.isEmpty)
        #expect(result.plan == PlanCounts(done: 0, slipped: 0, dropped: 0, moved: 0, open: 0))
    }

    @Test func graceWindowDecidesWhetherASealCounts() throws {
        let f = try Fixture(start: "2026-10-28")
        // Wednesday sealed on Thursday morning: inside grace.
        f.go("2026-10-29", 9, 0)
        let late = try f.journal.seal(f.day("2026-10-28"), actor: .cli)
        #expect(late.counts)
        // Thursday sealed on Saturday: past grace. Sealed, but it does not count.
        f.go("2026-10-31", 9, 0)
        let tooLate = try f.journal.seal(f.day("2026-10-29"), actor: .cli)
        #expect(!tooLate.counts)
        #expect(tooLate.streak.current == 0)  // Thursday is final and uncounted, so it ended the run Wednesday started
        #expect(try f.journal.dayView(f.day("2026-10-29")).day.sealedAt != nil)
    }

    @Test func sealingTwiceAndSealingTheFutureAreRefused() throws {
        let f = try Fixture()
        _ = try f.journal.seal(nil, actor: .cli)
        let again = validationMessage { _ = try f.journal.seal(nil, actor: .cli) }
        #expect(again == "2026-10-29 is already wrapped up at 18:00")
        let future = validationMessage { _ = try f.journal.seal(f.day("2026-10-30"), actor: .cli) }
        #expect(future == "date: 2026-10-30 is in the future")
        #expect(try f.store.events(subject: "day:2026-10-29").filter { $0.type == "day.sealed" }.count == 1)
    }

    @Test func carryOverSkipsTheWeekend() throws {
        let f = try Fixture(start: "2026-10-30")
        _ = try f.plan("Friday leftover", on: "2026-10-30")
        let result = try f.journal.seal(nil, actor: .cli)
        #expect(result.carried.first?.task.day == "2026-11-02")
    }

    @Test func carryOverSkipsLeaveAndHolidays() throws {
        let f = try Fixture(start: "2026-10-29")
        try f.journal.declare(f.day("2026-10-30"), kind: .leavePlanned, label: nil, actor: .cli)
        try f.journal.declare(f.day("2026-11-02"), kind: .holiday, label: "Example holiday", actor: .cli)
        _ = try f.plan("Thursday leftover", on: "2026-10-29")
        let result = try f.journal.seal(nil, actor: .cli)
        #expect(result.carried.first?.task.day == "2026-11-03")
    }

    @Test func carriedTasksChainAndAppendAfterTheTargetsOwnTasks() throws {
        let f = try Fixture(start: "2026-10-29")
        let original = try f.plan("Long running task", on: "2026-10-29")
        let existing = try f.plan("Planned for Friday", on: "2026-10-30")
        let first = try #require(try f.journal.seal(nil, actor: .cli).carried.first)
        #expect(first.task.position == existing.position + 1)
        #expect(first.task.carriedFrom == original.id)

        f.go("2026-10-30")
        let second = try #require(try f.journal.seal(nil, actor: .cli).carried.first { $0.task.title == "Long running task" })
        #expect(second.task.day == "2026-11-02")
        #expect(second.task.carriedFrom == first.task.id)
        #expect(try f.journal.task(first.task.id).status == .moved)
        // Friday's own open task moved too.
        let moved = try f.journal.dayView(f.day("2026-11-02")).tasks
        #expect(moved.map(\.title) == ["Planned for Friday", "Long running task"])
        #expect(moved.map(\.position) == [1, 2])
    }

    @Test func entriesLoggedAfterTheSealAreFlagged() throws {
        let f = try Fixture()
        let before = try f.journal.log(LogRequest(text: "Fixed it"), actor: .cli, origin: .selfReported)
        _ = try f.journal.seal(nil, actor: .cli)
        f.go("2026-10-29", 19, 2)
        let after = try f.journal.log(LogRequest(text: "Merged a late PR", kind: .prMerged), actor: .cli, origin: .selfReported)
        #expect(!before.afterSeal)
        #expect(after.afterSeal)
        #expect(try f.journal.entry(after.id).afterSeal)
    }

    @Test func rebuildGivesIdenticalProjections() throws {
        let f = try Fixture()
        _ = try f.journal.log(LogRequest(text: "Fixed it"), actor: .cli, origin: .selfReported)
        _ = try f.plan("Carry me", on: "2026-10-29")
        _ = try f.journal.seal(nil, actor: .cli)
        f.go("2026-10-30")
        _ = try f.plan("More", on: "2026-10-30")
        _ = try f.journal.seal(nil, actor: .cli)
        _ = try f.journal.standup(f.day("2026-10-30"))
        let before = try f.store.projectionDump()
        try f.store.rebuild()
        #expect(try f.store.projectionDump() == before)
    }

    // MARK: streak

    @Test func streakSkipsWeekends() throws {
        let f = try Fixture(start: "2026-10-12")
        for day in ["2026-10-12", "2026-10-13", "2026-10-14", "2026-10-15", "2026-10-16"] {
            _ = try f.seal(day, at: (day, 18, 0))
        }
        f.go("2026-10-19", 10, 0)
        var streak = try f.journal.streak()
        #expect(streak.current == 5 && streak.best == 5 && !streak.atRisk && streak.pausedBy.isEmpty)
        streak = try f.journal.seal(nil, actor: .cli).streak
        #expect(streak.current == 6)
    }

    @Test func streakIsPausedNotBrokenByLeaveAndHolidays() throws {
        let f = try Fixture(start: "2026-10-12")
        try f.journal.declare(f.day("2026-10-14"), kind: .leavePlanned, label: nil, actor: .cli)
        try f.journal.declare(f.day("2026-10-15"), kind: .holiday, label: nil, actor: .cli)
        for day in ["2026-10-12", "2026-10-13", "2026-10-16"] { _ = try f.seal(day, at: (day, 18, 0)) }
        let streak = try f.journal.streak()
        #expect(streak.current == 3)
        #expect(streak.pausedBy == [f.day("2026-10-14"), f.day("2026-10-15")])
        // A sealed leave day neither adds nor breaks.
        _ = try f.seal("2026-10-14", at: ("2026-10-16", 19, 0))
        #expect(try f.journal.streak().current == 3)
    }

    @Test func anUnsealedWorkdayPastGraceBreaksTheStreak() throws {
        let f = try Fixture(start: "2026-10-12")
        for day in ["2026-10-12", "2026-10-13"] { _ = try f.seal(day, at: (day, 18, 0)) }
        // Wednesday is never sealed. Thursday and Friday are.
        for day in ["2026-10-15", "2026-10-16"] { _ = try f.seal(day, at: (day, 18, 0)) }
        f.go("2026-10-17", 10, 0)
        let streak = try f.journal.streak()
        #expect(streak.current == 2)
        #expect(streak.best == 2)
        #expect(!streak.atRisk)
    }

    @Test func yesterdayInGraceIsAtRiskNotBroken() throws {
        let f = try Fixture(start: "2026-10-12")
        for day in ["2026-10-12", "2026-10-13"] { _ = try f.seal(day, at: (day, 18, 0)) }
        f.go("2026-10-15", 10, 0)  // Wednesday 14 is unsealed, still inside grace
        var streak = try f.journal.streak()
        #expect(streak.current == 2 && streak.atRisk)
        let result = try f.journal.seal(f.day("2026-10-14"), actor: .cli)
        #expect(result.counts)
        streak = result.streak
        #expect(streak.current == 3 && !streak.atRisk)
    }

    @Test func bestKeepsTheLongestRunAfterABreak() throws {
        let f = try Fixture(start: "2026-10-05")
        for day in ["2026-10-05", "2026-10-06", "2026-10-07", "2026-10-08"] { _ = try f.seal(day, at: (day, 18, 0)) }
        // Friday the 9th is missed; the next week has two seals.
        for day in ["2026-10-12", "2026-10-13"] { _ = try f.seal(day, at: (day, 18, 0)) }
        f.go("2026-10-14", 10, 0)
        let streak = try f.journal.streak()
        #expect(streak.current == 2)
        #expect(streak.best == 4)
        // An as-of view ignores seals that had not happened yet.
        let earlier = try f.journal.streak(asOf: f.day("2026-10-08"))
        #expect(earlier.current == 4 && earlier.best == 4)
        #expect(validationMessage { _ = try f.journal.streak(asOf: f.day("2026-10-15")) } != nil)
    }

    @Test func emptyLedgerHasNoStreak() throws {
        let f = try Fixture()
        #expect(try f.journal.streak() == Streak())
    }

    /// Workdays 2026-10-01 (Thu) to 2026-10-29 (Thu) are 21: 1, 2, then 5, 5, 5 (weeks of the 5th, 12th, 19th)
    /// and 4 (26 to 29). 2026-10-02 is a declared holiday, so it is paused and not counted: 21 - 1 = 20.
    /// Weekends (3, 4, 10, 11, 17, 18, 24, 25) are skipped. Every other workday is sealed at 18:00 the same day.
    @Test func octoberRunCountsTwentyWorkdays() throws {
        let f = try Fixture(start: "2026-10-01")
        try f.journal.declare(f.day("2026-10-02"), kind: .holiday, label: "Gandhi Jayanti", actor: .cli)
        var last: SealResult?
        for day in LocalDate.range(f.day("2026-10-01"), through: f.day("2026-10-29")) {
            guard DayRules(config: f.journal.config).kind(of: day, declared: day.description == "2026-10-02" ? .holiday : nil) == .workday
            else { continue }
            f.go(day.description)
            last = try f.journal.seal(day, actor: .cli)
        }
        let streak = try #require(last?.streak)
        #expect(streak.current == 20)
        #expect(streak.best == 20)
        #expect(streak.pausedBy == [f.day("2026-10-02")])
        #expect(!streak.atRisk)
        #expect(try f.journal.streak(asOf: f.day("2026-10-29")) == streak)
    }

    @Test func graceEndFollowsDaylightSavingTime() throws {
        let ny = TimeZone(identifier: "America/New_York")!
        let rules = DayRules()
        // 2026-11-01 is the 25-hour day (clocks fall back at 02:00). Grace ends at 23:59:59.999 on 11-02 EST.
        #expect(Timestamp.utc(rules.graceEnd(of: LocalDate("2026-11-01")!, in: ny)) == "2026-11-03T04:59:59.999Z")
        // A day before the change: 11-02 00:00 is already EST (UTC-5).
        #expect(Timestamp.utc(rules.graceEnd(of: LocalDate("2026-10-31")!, in: ny)) == "2026-11-02T04:59:59.999Z")
        #expect(Timestamp.utc(rules.graceEnd(of: LocalDate("2026-10-30")!, in: ny)) == "2026-11-01T03:59:59.999Z")
        let eleven30 = Timestamp.resolve(LocalDate("2026-11-02")!, hour: 23, minute: 30, in: ny)
        let past = Timestamp.resolve(LocalDate("2026-11-03")!, hour: 0, minute: 30, in: ny)
        #expect(rules.sealCounts(eleven30, for: LocalDate("2026-11-01")!, in: ny))
        #expect(!rules.sealCounts(past, for: LocalDate("2026-11-01")!, in: ny))
    }

    // MARK: stand-up

    @Test func standupMatchesTheSpecShape() throws {
        let f = try Fixture(start: "2026-10-29", hour: 17)
        _ = try f.journal.log(
            LogRequest(text: "Shipped retry budget for capture path", kind: .shipped, ticket: "ACME-482913"),
            actor: .cli, origin: .selfReported)
        _ = try f.journal.log(
            LogRequest(text: "Merged the capture PR", kind: .prMerged), actor: .cli, origin: .selfReported)
        _ = try f.journal.log(
            LogRequest(text: "Reviewed settlement batching RFC", kind: .docReviewed, quantity: 3), actor: .cli,
            origin: .selfReported)
        _ = try f.journal.log(
            LogRequest(text: "Paired on the flaky ledger test", kind: .mentoring), actor: .cli, origin: .selfReported)
        _ = try f.journal.log(LogRequest(text: "Standup", kind: .meetingAttended), actor: .cli, origin: .selfReported)
        let dismissed = try f.journal.log(LogRequest(text: "Not accepted", kind: .shipped), actor: .mcp, origin: .agent)
        _ = try f.journal.setStatus(entryID: dismissed.id, to: .dismissed, note: nil, actor: .cli)
        for (i, id) in ["s1", "s2"].enumerated() {
            let session = GenAISession(
                sessionId: id, tool: "claude-code", day: "2026-10-29", startedAt: "2026-10-29T1\(i):00:00+05:30")
            try f.store.append([EventPayload.genaiSession(session).draft(actor: .hook)])
        }
        let slipped = try f.plan("Draft idempotency ADR", on: "2026-10-29")
        _ = try f.journal.planResolve(taskID: slipped.id, status: .slipped, reason: "reprioritised", note: nil, links: [], actor: .cli)
        let carried = PlanTask(
            id: "01TESTCARRIED000000000001", day: "2026-10-30", position: 1, title: "Draft idempotency ADR",
            origin: .carried, carriedFrom: slipped.id, plannedAt: "2026-10-29T17:00:00+05:30")
        try f.store.append([EventPayload.planAdded(carried).draft(actor: .cli)])
        _ = try f.journal.planAdd(
            title: "Prototype webhook replay tool ACME-000000", day: f.day("2026-10-30"), estimateMin: nil,
            origin: .selfReported, actor: .cli)

        let result = try f.journal.standup(f.day("2026-10-29"))
        let expected = """
            *Thu 29 Oct*
            Done
            \u{2022} Shipped retry budget for capture path (ACME-482913)
            \u{2022} Merged the capture PR
            \u{2022} Reviewed settlement batching RFC
            \u{2022} Paired on the flaky ledger test
            Reviews 3 \u{00B7} PRs merged 1 \u{00B7} Claude Code 2 sessions
            Next
            \u{2022} Draft idempotency ADR (slipped: reprioritised)
            \u{2022} Prototype webhook replay tool ACME-000000
            Blockers: none
            cadence \(result.code)
            """
        #expect(result.text == expected)
        #expect(result.code.count == 16)
        #expect(!result.text.contains("\u{2013}") && !result.text.contains("\u{2014}"))
        let found = try #require(try f.store.find(witnessCode: result.code))
        #expect(found.type == "witness.checkpoint")
        // Copying again with nothing new in between gives the same code and adds no event.
        let count = try f.store.eventCount()
        #expect(try f.journal.standup(f.day("2026-10-29")) == result)
        #expect(try f.store.eventCount() == count)
    }

    @Test func standupForAQuietDayAndFutureDay() throws {
        let f = try Fixture()
        let result = try f.journal.standup(nil)
        #expect(
            result.text == "*Thu 29 Oct*\nDone\n\u{2022} Nothing logged\nNext\n\u{2022} Nothing planned\nBlockers: none\ncadence \(result.code)")
        #expect(validationMessage { _ = try f.journal.standup(f.day("2026-10-30")) } != nil)
    }
}
