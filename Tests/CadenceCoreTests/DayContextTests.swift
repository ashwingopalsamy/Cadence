import Foundation
import Testing

@testable import CadenceCore

/// The day context the app reads for every surface, and the morning plan commit (docs/SPEC.md sections 4.4, 5.2).
@Suite struct DayContextTests {
    typealias F = DayMechanicsTests.Fixture

    @Test func aCommitListsTheDaysTasksAndIsReadBack() throws {
        let f = try F(start: "2026-10-29", hour: 9)
        let a = try f.plan("Write ADR", on: "2026-10-29")
        let b = try f.plan("Review RFC", on: "2026-10-29")
        #expect(!(try f.journal.isPlanCommitted(f.day("2026-10-29"))))
        try f.journal.planCommit(day: f.day("2026-10-29"), tasks: [b.id, a.id], focus: " Ship it ", actor: .app)
        #expect(try f.journal.isPlanCommitted(f.day("2026-10-29")))
        #expect(!(try f.journal.isPlanCommitted(f.day("2026-10-30"))))
        let view = try f.journal.dayView(f.day("2026-10-29"))
        #expect(view.tasks.map(\.id) == [b.id, a.id])
        #expect(view.day.focus == "Ship it")
    }

    @Test func aCommitRefusesTasksOfAnotherDayDuplicatesAndUnknownIDs() throws {
        let f = try F(start: "2026-10-29", hour: 9)
        let a = try f.plan("Write ADR", on: "2026-10-29")
        let other = try f.plan("Tomorrow", on: "2026-10-30")
        #expect(throws: CadenceError.self) { try f.journal.planCommit(day: f.day("2026-10-29"), tasks: [a.id, a.id], focus: nil, actor: .app) }
        #expect(throws: CadenceError.self) { try f.journal.planCommit(day: f.day("2026-10-29"), tasks: [other.id], focus: nil, actor: .app) }
        #expect(throws: CadenceError.self) { try f.journal.planCommit(day: f.day("2026-10-29"), tasks: ["nope"], focus: nil, actor: .app) }
        #expect(!(try f.journal.isPlanCommitted(f.day("2026-10-29"))))
    }

    @Test func carriedTasksWaitOutsideThePlanUntilItIsCommitted() throws {
        let f = try F(start: "2026-10-29", hour: 9)
        _ = try f.plan("Left open", on: "2026-10-29")
        _ = try f.seal("2026-10-29", at: ("2026-10-29", 18, 0))
        f.go("2026-10-30", 9, 0)
        let mine = try f.plan("Added by hand", on: "2026-10-30")
        var context = try f.journal.dayContext()
        #expect(context.carried.map(\.title) == ["Left open"])
        #expect(context.plan.map(\.id) == [mine.id])
        try f.journal.planCommit(day: nil, tasks: [context.carried[0].id, mine.id], focus: nil, actor: .app)
        context = try f.journal.dayContext()
        #expect(context.carried.isEmpty)
        #expect(context.plan.map(\.title) == ["Left open", "Added by hand"])
        #expect(context.storyInput(at: f.clock.now()).planned == 2)
    }

    @Test func movingATaskSlipsItHereAndCarriesItToTheNextWorkday() throws {
        let f = try F(start: "2026-10-30", hour: 17)  // a Friday
        let task = try f.plan("Draft the ADR", on: "2026-10-30")
        let carried = try f.journal.planMove(taskID: task.id, reason: SlipReason.reprioritised.rawValue, actor: .app)
        #expect(try f.journal.task(task.id).status == .slipped)
        #expect(try f.journal.task(task.id).reason == "reprioritised")
        #expect(carried.task.day == "2026-11-02")  // Monday, past the weekend
        #expect(carried.task.origin == .carried && carried.task.carriedFrom == task.id)
        f.go("2026-11-02", 9, 0)
        #expect(try f.journal.dayContext().carried.map(\.title) == ["Draft the ADR"])
        // A task that is not open cannot be moved again.
        #expect(throws: CadenceError.self) { try f.journal.planMove(taskID: task.id, reason: "blocked", actor: .app) }
    }

    @Test func anEditKeepsTheOldVersionAndTheOrigin() throws {
        let f = try F(start: "2026-10-29", hour: 11)
        let entry = try f.journal.log(LogRequest(text: "Mentoring", kind: .mentoring), actor: .cli, origin: .selfReported)
        let edited = try f.journal.entryEdit(entryID: entry.id, title: "Mentored on the ledger model", kind: .meetingLed, actor: .app)
        #expect(edited.title == "Mentored on the ledger model")
        #expect(edited.kind == .meetingLed && edited.family == .leadership)
        #expect(edited.origin == entry.origin)
        #expect(try f.journal.history(subject: "entry:\(entry.id)").map(\.type) == ["entry.created", "entry.updated"])
        // Nothing changed means nothing written.
        _ = try f.journal.entryEdit(entryID: entry.id, title: "Mentored on the ledger model", kind: nil, actor: .app)
        #expect(try f.journal.history(subject: "entry:\(entry.id)").count == 2)
        #expect(throws: CadenceError.self) { try f.journal.entryEdit(entryID: entry.id, title: "  ", kind: nil, actor: .app) }
    }

    @Test func carriedTasksLeftBehindAreNotTodaysPlan() throws {
        let f = try F(start: "2026-10-29", hour: 9)
        _ = try f.plan("Keep this", on: "2026-10-29")
        _ = try f.plan("Leave this", on: "2026-10-29")
        _ = try f.seal("2026-10-29", at: ("2026-10-29", 18, 0))
        f.go("2026-10-30", 9, 0)
        let carried = try f.journal.dayContext().carried
        let keep = try #require(carried.first { $0.title == "Keep this" })
        let leave = try #require(carried.first { $0.title == "Leave this" })
        _ = try f.journal.planResolve(taskID: leave.id, status: .dropped, reason: nil, note: nil, links: [], actor: .app)
        try f.journal.planCommit(day: nil, tasks: [keep.id], focus: nil, actor: .app)
        let context = try f.journal.dayContext()
        #expect(context.plan.map(\.title) == ["Keep this"])
        #expect(context.storyInput(at: f.clock.now()).planned == 1)
    }

    @Test func thePreviousDayLeadsOnlyUntilTodayHasSomething() throws {
        let f = try F(start: "2026-10-29", hour: 9)
        _ = try f.journal.log(LogRequest(text: "Reviewed the RFC", kind: .docReviewed), actor: .cli, origin: .selfReported)
        f.go("2026-10-30", 9, 0)
        #expect(DayStory(try f.journal.dayContext().storyInput(at: f.clock.now())).state == .yesterdayOpen)
        _ = try f.journal.log(LogRequest(text: "Merged the retry budget", kind: .prMerged), actor: .cli, origin: .selfReported)
        let context = try f.journal.dayContext()
        #expect(context.previous?.graceOpen == true)  // the card stays while its window is open
        #expect(context.previous?.leads == false)
        #expect(DayStory(context.storyInput(at: f.clock.now())).state != .yesterdayOpen)
    }

    @Test func suggestionsComeFromOpenPullRequestsAndYesterdaysTicketsNeverInvented() throws {
        let f = try F(start: "2026-10-29", hour: 11)
        _ = try f.journal.log(LogRequest(text: "Opened ACME-482913 retry budget", kind: .prOpened), actor: .cli, origin: .selfReported)
        _ = try f.journal.log(LogRequest(text: "Opened ACME-482877 spool drain", kind: .prOpened), actor: .cli, origin: .selfReported)
        _ = try f.journal.log(LogRequest(text: "Merged ACME-482877 spool drain", kind: .prMerged), actor: .cli, origin: .selfReported)
        _ = try f.journal.log(LogRequest(text: "Fixed ACME-482990 flaky ledger test", kind: .workDone), actor: .cli, origin: .selfReported)
        f.go("2026-10-30", 9, 0)
        let titles = try f.journal.dayContext().suggestions.map(\.title)
        #expect(titles.contains("Opened ACME-482913 retry budget"))
        #expect(!titles.contains("Opened ACME-482877 spool drain"))  // merged since
        #expect(titles.contains("Fixed ACME-482990 flaky ledger test"))
        // Once planned, a suggestion is not offered again, and a committed day has none.
        _ = try f.plan("Opened ACME-482913 retry budget", on: "2026-10-30")
        #expect(!(try f.journal.dayContext().suggestions.map(\.title).contains("Opened ACME-482913 retry budget")))
        try f.journal.planCommit(day: nil, tasks: [], focus: nil, actor: .app)
        #expect(try f.journal.dayContext().suggestions.isEmpty)
    }

    @Test func yesterdayOpenInItsGraceWindowThenClosedUnsealed() throws {
        let f = try F(start: "2026-10-29", hour: 9)
        _ = try f.journal.log(LogRequest(text: "Reviewed the RFC", kind: .docReviewed), actor: .cli, origin: .selfReported)
        f.go("2026-10-30", 10, 0)
        var previous = try #require(try f.journal.dayContext().previous)
        #expect(previous.date == f.day("2026-10-29"))
        #expect(previous.graceOpen)
        // Monday 2 Nov: Friday is the last workday, and Thursday's window closed long ago.
        _ = try f.journal.log(LogRequest(text: "Finished the spool drain", kind: .workDone), actor: .cli, origin: .selfReported)
        f.go("2026-11-02", 10, 0)
        previous = try #require(try f.journal.dayContext().previous)
        #expect(previous.date == f.day("2026-10-30"))
        #expect(!previous.graceOpen)
    }

    @Test func theWeekCountsSealedWorkdaysAndYesterdayCarriesItsCounts() throws {
        let f = try F(start: "2026-10-26", hour: 9)  // Monday
        _ = try f.journal.log(LogRequest(text: "Reviewed the RFC", kind: .docReviewed), actor: .cli, origin: .selfReported)
        _ = try f.seal("2026-10-26", at: ("2026-10-26", 18, 0))
        f.go("2026-10-27", 9, 0)
        let a = try f.plan("Write ADR", on: "2026-10-27")
        _ = try f.plan("Review RFC", on: "2026-10-27")
        _ = try f.journal.planResolve(taskID: a.id, status: .done, reason: nil, note: nil, links: [], actor: .cli)
        _ = try f.journal.log(LogRequest(text: "Merged the retry budget", kind: .prMerged), actor: .cli, origin: .selfReported)
        f.go("2026-10-28", 10, 0)  // Wednesday: Monday sealed, Tuesday not, today not counted yet
        let context = try f.journal.dayContext()
        #expect(context.weekWorkdays == 2 && context.weekSealed == 1)
        let previous = try #require(context.previous)
        #expect(previous.planned == 2 && previous.done == 1 && previous.items == 1)
    }

    @Test func aSealedOrEmptyPreviousDayIsNothingToReport() throws {
        let f = try F(start: "2026-10-29", hour: 9)
        _ = try f.journal.log(LogRequest(text: "Reviewed the RFC", kind: .docReviewed), actor: .cli, origin: .selfReported)
        _ = try f.seal("2026-10-29", at: ("2026-10-29", 18, 0))
        f.go("2026-10-30", 10, 0)
        #expect(try f.journal.dayContext().previous == nil)
        f.go("2026-11-02", 10, 0)  // Friday had nothing on it
        #expect(try f.journal.dayContext().previous == nil)
    }

    @Test func theWrapReminderPassesAtItsTimeInTheDaysZone() throws {
        let f = try F(start: "2026-10-29", hour: 17)
        let context = try f.journal.dayContext()
        #expect(context.wrapReminders == ["17:30"])
        #expect(context.passedReminder(at: Timestamp.resolve(f.day("2026-10-29"), hour: 17, minute: 29, in: f.zone)) == nil)
        #expect(context.passedReminder(at: Timestamp.resolve(f.day("2026-10-29"), hour: 17, minute: 30, in: f.zone)) == "17:30")
        // After midnight the evening's reminder has still passed; at 04:00 the next day begins.
        #expect(context.passedReminder(at: Timestamp.resolve(f.day("2026-10-30"), hour: 1, minute: 15, in: f.zone)) == "17:30")
        #expect(context.passedReminder(at: Timestamp.resolve(f.day("2026-10-30"), hour: 4, minute: 0, in: f.zone)) == nil)
    }

    @Test func theStoryInputCarriesWhatTheStoreKnows() throws {
        let f = try F(start: "2026-10-29", hour: 11)
        let a = try f.plan("Write ADR", on: "2026-10-29")
        _ = try f.plan("Review RFC", on: "2026-10-29")
        _ = try f.journal.planResolve(taskID: a.id, status: .done, reason: nil, note: nil, links: [], actor: .cli)
        _ = try f.journal.log(LogRequest(text: "Merged the retry budget", kind: .prMerged), actor: .cli, origin: .selfReported)
        try f.journal.declare(f.day("2026-10-29"), kind: .leaveUnplanned, label: "Sick", actor: .cli)
        let input = try f.journal.dayContext().storyInput(at: f.clock.now())
        #expect(input.planned == 2 && input.resolved == 1 && input.done == 1)
        #expect(input.items == 1)
        #expect(input.dayOff == .sick)
        #expect(input.wrapUpReminder == nil)
        #expect(DayStory(input).state == .sick)
    }
}
