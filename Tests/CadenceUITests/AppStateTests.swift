import CadenceCore
import Foundation
import Testing

@testable import CadenceUI

/// The shared model: the tick held for Undo, the morning commit, days off and failures (docs/SPEC.md 4.2, 4.4).
@MainActor @Suite struct AppStateTests {
    typealias Home = DayStoreLoaderTests.Home

    /// An app state on a temp home whose store already exists, read once.
    static func make(_ home: Home) async throws -> AppState {
        try ConfigStore.save(Config.defaults(timezone: "Asia/Kolkata"), to: home.roots.config)
        let clock = DayStoreLoaderTests.FixedClock()
        let model = DayModel(loader: DayStoreLoader(location: .found(home.roots), clock: clock))
        let app = AppState(model: model, writer: AppWriter(location: .found(home.roots), clock: clock, poster: AppWriterTests.CountingPoster()), clock: clock)
        _ = await app.perform(.planAdd(title: "Write the ADR", day: nil))
        _ = await app.perform(.planAdd(title: "Review the RFC", day: nil))
        await settle(app)
        return app
    }

    /// Waits until the model has read the latest write.
    static func settle(_ app: AppState) async {
        let before = app.model.reads
        app.model.reload()
        for _ in 0..<1500 where app.model.reads == before {
            try? await Task.sleep(for: .milliseconds(10))
        }
        // One more pass, so a read already running when the reload was asked for is followed by a fresh one.
        let after = app.model.reads
        for _ in 0..<10 where app.model.reads == after && app.model.reads < before + 2 {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test func aTickReadsAsDoneAtOnceAndUndoWritesNothing() async throws {
        let home = Home()
        defer { home.remove() }
        let app = try await Self.make(home)
        let task = try #require(app.context?.plan.first)
        app.tick(task)
        #expect(app.status(of: task) == .done)
        #expect(app.shownDone == 1)
        app.undoTick()
        #expect(app.status(of: task) == .open)
        await Self.settle(app)
        #expect(app.context?.plan.first?.status == .open)
    }

    @Test func aSecondTickWritesTheFirstAndHoldsItsOwnUndo() async throws {
        let home = Home()
        defer { home.remove() }
        let app = try await Self.make(home)
        let plan = try #require(app.context?.plan)
        app.tick(plan[0])
        app.tick(plan[1])
        #expect(app.pendingTick?.task == plan[1].id)
        #expect(app.shownDone == 1)  // the second is shown done; the first is being written
        for _ in 0..<100 where app.context?.plan.first?.status != .done {
            try? await Task.sleep(for: .milliseconds(10))
            await Self.settle(app)
        }
        #expect(app.context?.plan.map(\.status) == [.done, .open])
        #expect(app.shownDone == 2)
        app.undoTick()
        await Self.settle(app)
        #expect(app.context?.plan.map(\.status) == [.done, .open])
    }

    /// What VoiceOver would have been told.
    @MainActor final class Heard {
        var lines: [String] = []
    }

    @Test func oneTickIsAnnouncedOnceAsDoneNOfM() async throws {
        let home = Home()
        defer { home.remove() }
        let app = try await Self.make(home)
        let heard = Heard()
        app.announce = { heard.lines.append($0) }
        let task = try #require(app.context?.plan.first)
        app.tick(task)
        #expect(heard.lines == ["Done, 1 of 2"])
        // The same tick again, and the write when it is flushed, say nothing more.
        app.tick(task)
        await app.flushPendingTick()
        await Self.settle(app)
        #expect(heard.lines == ["Done, 1 of 2"])
    }

    @Test func undoSaysNothingAndTheNextTickIsAnnouncedAgain() async throws {
        let home = Home()
        defer { home.remove() }
        let app = try await Self.make(home)
        let heard = Heard()
        app.announce = { heard.lines.append($0) }
        let task = try #require(app.context?.plan.first)
        app.tick(task)
        app.undoTick()
        #expect(heard.lines == ["Done, 1 of 2"])
        app.tick(task)
        #expect(heard.lines == ["Done, 1 of 2", "Done, 1 of 2"])
    }

    @Test func aTickOnADoneTaskSaysNothing() async throws {
        let home = Home()
        defer { home.remove() }
        let app = try await Self.make(home)
        let task = try #require(app.context?.plan.first)
        app.tick(task)
        await app.flushPendingTick()
        await Self.settle(app)
        let heard = Heard()
        app.announce = { heard.lines.append($0) }
        app.tick(try #require(app.context?.plan.first))
        #expect(heard.lines.isEmpty)
    }

    @Test func aSecondTickCountsTheFirstThatIsStillBeingWritten() async throws {
        let home = Home()
        defer { home.remove() }
        let app = try await Self.make(home)
        let heard = Heard()
        app.announce = { heard.lines.append($0) }
        let plan = try #require(app.context?.plan)
        app.tick(plan[0])
        app.tick(plan[1])
        #expect(heard.lines == ["Done, 1 of 2", "Done, 2 of 2"])
    }

    @Test func theTickAnnouncementIsDoneNOfM() {
        #expect(AppState.tickAnnouncement(done: 3, planned: 5) == "Done, 3 of 5")
    }

    @Test func aFlushedTickIsWritten() async throws {
        let home = Home()
        defer { home.remove() }
        let app = try await Self.make(home)
        let task = try #require(app.context?.plan.first)
        app.tick(task)
        await app.flushPendingTick()
        #expect(app.pendingTick == nil)
        await Self.settle(app)
        #expect(app.context?.plan.first?.status == .done)
        // A done task is not ticked again: the ledger has no reopen.
        app.tick(try #require(app.context?.plan.first))
        #expect(app.pendingTick == nil)
    }

    @Test func aTakenTickIsHandedOverOnce() async throws {
        let home = Home()
        defer { home.remove() }
        let app = try await Self.make(home)
        let task = try #require(app.context?.plan.first)
        app.tick(task)
        #expect(app.takePendingTick() == task.id)
        #expect(app.takePendingTick() == nil && app.pendingTick == nil)
    }

    @Test func theMorningCommitAddsDropsAndOrders() async throws {
        let home = Home()
        defer { home.remove() }
        let app = try await Self.make(home)
        let ids = try #require(app.context?.plan.map(\.id))
        #expect(await app.commitPlan(picked: [ids[1]], added: ["Draft the replay tool"]))
        await Self.settle(app)
        #expect(app.context?.committed == true)
        #expect(app.context?.plan.map(\.title).prefix(2) == ["Review the RFC", "Draft the replay tool"])
    }

    @Test func sickLeaveIsTheSickStateAndWorkingAfterAllUndoesIt() async throws {
        let home = Home()
        defer { home.remove() }
        let app = try await Self.make(home)
        #expect(await app.declare(.sick))
        await Self.settle(app)
        #expect(app.story?.state == .sick)
        #expect(await app.workingAfterAll())
        await Self.settle(app)
        #expect(app.story?.state != .sick)
    }

    @Test func aRefusedWriteIsKeptForTheBannerUntilTheNextSuccess() async throws {
        let home = Home()
        defer { home.remove() }
        let app = try await Self.make(home)
        #expect(!(await app.resolve("missing", as: .done)))
        #expect(app.issue?.kind == .invalid)
        #expect(await app.log("Merged the retry budget") != nil)
        #expect(app.issue == nil)
    }

    @Test func aLineThatCouldNotBeSavedIsKeptForCopyMyText() async throws {
        let home = Home()
        defer { home.remove() }
        let app = try await Self.make(home)
        // A day in the future is refused by the ledger, so the words stay with the app.
        _ = await app.perform(.log(LogRequest(text: "Merged the retry budget", date: LocalDate("2099-01-01")!)))
        #expect(app.issue != nil)
        #expect(app.unsavedText == "Merged the retry budget")
        #expect(await app.log("Reviewed the RFC") != nil)
        #expect(app.unsavedText == nil && app.issue == nil)
    }

    // MARK: a line with a picked kind and links (T4.17)

    @Test func aPickedKindIsSavedInPlaceOfTheOneTheWordsSay() async throws {
        let home = Home()
        defer { home.remove() }
        let app = try await Self.make(home)
        // Nothing in the words names a kind, so without a pick this is a note, hidden from the counts.
        let plain = try #require(await app.log("Went through the retry fix"))
        #expect(plain.kind == .note && plain.export == .digest)
        let picked = try #require(await app.log("Went through the retry fix", kind: .reviewGiven))
        #expect(picked.kind == .reviewGiven && picked.family == .review && picked.export == .include)
        #expect(picked.origin == .selfReported)
        // The code review phrase saves as a review without a pick.
        #expect(try #require(await app.log("Code review of the retry fix")).kind == .reviewGiven)
    }

    @Test func aLinkInTheLineLeavesTheTitleAndIsSavedWithTheEntry() async throws {
        let home = Home()
        defer { home.remove() }
        let app = try await Self.make(home)
        let pr = "https://git.example.com/acme/api/pull/88"
        let reviewed = try #require(await app.log("Reviewed \(pr)"))
        #expect(reviewed.title == "Reviewed" && reviewed.kind == .reviewGiven)
        #expect(reviewed.links == [Link(kind: .pr, url: pr)])
        let only = try #require(await app.log(pr))
        #expect(only.title == "PR #88 in acme/api" && only.links.count == 1)
    }

    @Test func linksGivenToLogAreCheckedByTheSameRule() async throws {
        let home = Home()
        defer { home.remove() }
        let app = try await Self.make(home)
        let kept = try #require(await app.log("Reviewed the RFC", links: [Link(kind: .other, url: "https://docs.example.com/rfc")]))
        #expect(kept.links.map(\.url) == ["https://docs.example.com/rfc"])
        // A link the ledger refuses saves nothing, and the words stay for Copy my text.
        #expect(await app.log("Reviewed the other RFC", links: [Link(kind: .other, url: "http://docs.example.com/rfc")]) == nil)
        #expect(app.issue?.kind == .invalid)
        #expect(app.unsavedText == "Reviewed the other RFC")
    }

    @Test func aLineLogsOntoTheDayItIsFor() async throws {
        let home = Home()
        defer { home.remove() }
        let app = try await Self.make(home)
        let day = app.today.adding(days: -1)
        let entry = try #require(await app.log("Reviewed the RFC", day: day))
        #expect(entry.day == day.description && entry.backfilled)
        #expect(try #require(await app.log("Reviewed the other RFC")).day == app.today.description)
    }

    @Test func editingAnEntrysLinksAddsAVersion() async throws {
        let home = Home()
        defer { home.remove() }
        let app = try await Self.make(home)
        let entry = try #require(await app.log("Reviewed the RFC"))
        let pr = Link(kind: .pr, url: "https://git.example.com/acme/api/pull/88")
        #expect(await app.editEntry(entry.id, links: [pr]))
        #expect(await app.editEntry(entry.id, links: []))
        #expect(!(await app.editEntry(entry.id, links: [Link(kind: .other, url: "ftp://example.com/x")])))
        #expect(app.issue?.kind == .invalid)
        let journal = try home.journal()
        #expect(try journal.history(subject: "entry:\(entry.id)").map(\.type) == ["entry.created", "entry.updated", "entry.updated"])
        #expect(try journal.entry(entry.id).links.isEmpty)
    }

    // MARK: reopening a sealed day (T4.18)

    @Test func reopeningASealedDayUnsealsItAndSealingAgainSealsIt() async throws {
        let home = Home()
        defer { home.remove() }
        let app = try await Self.make(home)
        #expect(await app.seal(standup: false) != nil)
        await Self.settle(app)
        #expect(app.state?.isSealed == true)
        #expect(app.context?.history.map(\.kind) == [.sealed])

        #expect(await app.reopen(day: app.today))
        await Self.settle(app)
        #expect(app.state?.isSealed == false)
        #expect(app.context?.history.map(\.kind) == [.sealed, .reopened])
        #expect(app.issue == nil)

        #expect(await app.seal(standup: false) != nil)
        await Self.settle(app)
        #expect(app.state?.isSealed == true)
        #expect(app.context?.history.map(\.kind) == [.sealed, .reopened, .sealed])
    }

    @Test func reopeningADayThatIsNotSealedIsRefusedAndShownInTheBanner() async throws {
        let home = Home()
        defer { home.remove() }
        let app = try await Self.make(home)
        #expect(!(await app.reopen(day: app.today)))
        #expect(app.issue?.kind == .invalid)
        #expect(app.issue?.detail.contains("not wrapped up") == true)
        // The next write that works clears it.
        #expect(await app.log("Reviewed the RFC") != nil)
        #expect(app.issue == nil)
    }

    @Test func anEarlierDayIsReopenedByDate() async throws {
        let home = Home()
        defer { home.remove() }
        let app = try await Self.make(home)
        let yesterday = app.today.adding(days: -1)
        let journal = try home.journal()
        _ = try journal.seal(yesterday, actor: .cli)
        #expect(await app.reopen(day: yesterday))
        #expect(try journal.dayHistory(yesterday).map(\.kind) == [.sealed, .reopened])
        #expect(try journal.dayView(yesterday).day.sealedAt == nil)
        // Today was not touched.
        #expect(try journal.dayHistory(app.today).isEmpty)
        // A day in the future cannot be reopened.
        #expect(!(await app.reopen(day: app.today.adding(days: 1))))
    }

    @Test func aTickOnAnotherDaysTaskIsAnnouncedAgainstThatDaysPlan() async throws {
        let home = Home()
        defer { home.remove() }
        let app = try await Self.make(home)
        let heard = Heard()
        app.announce = { heard.lines.append($0) }
        let task = PlanTask(id: "t1", day: "2026-09-20", position: 1, title: "Write the notes", origin: .selfReported, plannedAt: "2026-09-20T10:00:00+05:30")
        let other = PlanTask(id: "t2", day: "2026-09-20", position: 2, title: "Review the RFC", origin: .selfReported, plannedAt: "2026-09-20T10:00:00+05:30")
        app.tick(task, among: [task, other])
        #expect(heard.lines == ["Done, 1 of 2"])
        app.undoTick()
    }

    @Test func discreetModeHidesTitlesAndTempo() async throws {
        let home = Home()
        defer { home.remove() }
        let app = try await Self.make(home)
        #expect(app.title("Write the ADR", index: 0, word: "Task") == "Write the ADR")
        app.discreet = true
        #expect(app.title("Write the ADR", index: 0, word: "Task") == "Task 1")
        #expect(!app.showsTempo)
    }
}
