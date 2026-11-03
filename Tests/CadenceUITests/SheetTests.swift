import CadenceCore
import Foundation
import Testing

@testable import CadenceUI

/// The morning plan sheet (docs/SPEC.md section 4.4).
@MainActor @Suite struct PlanSheetTests {
    typealias Home = DayStoreLoaderTests.Home

    /// Friday 18 Sep left two tasks open and was sealed, so Monday 21 Sep (the fixed clock's day) has them carried,
    /// and one task was added by hand on Monday before the sheet opened.
    static func make(_ home: Home) async throws -> AppState {
        let journal = try home.journal()
        let friday = LocalDate(year: 2026, month: 9, day: 18)!
        _ = try journal.planAdd(title: "Draft the idempotency ADR", day: friday, estimateMin: nil, origin: .selfReported, actor: .cli)
        _ = try journal.planAdd(title: "Prototype the ACME-000000 replay tool", day: friday, estimateMin: nil, origin: .selfReported, actor: .cli)
        _ = try journal.seal(friday, actor: .cli)
        _ = try journal.planAdd(title: "Answer the RFC comments", day: nil, estimateMin: nil, origin: .selfReported, actor: .cli)
        let clock = DayStoreLoaderTests.FixedClock()
        let model = DayModel(loader: home.loader)
        let app = AppState(
            model: model, writer: AppWriter(location: .found(home.roots), clock: clock, poster: AppWriterTests.CountingPoster()),
            clock: clock)
        await AppStateTests.settle(app)
        return app
    }

    static let suggestions = [
        PlanSuggestion(title: "Review the proof export PR", family: .review, reason: "Review requested on GitHub"),
        PlanSuggestion(title: "Follow up on the webhook retry alert", family: .ownership, reason: "From yesterday's incident"),
    ]

    @Test func carriedStartTickedAndSuggestionsWaitToBePicked() async throws {
        let home = Home()
        defer { home.remove() }
        let app = try await Self.make(home)
        let model = try #require(PlanSheetModel(app: app, suggestions: Self.suggestions))
        let carried = model.rows(in: .carried)
        #expect(carried.map(\.title) == ["Draft the idempotency ADR", "Prototype the ACME-000000 replay tool"])
        #expect(carried.allSatisfy(model.isPicked))
        #expect(carried.allSatisfy { $0.note == "Carried" })
        let suggested = model.rows(in: .suggested)
        #expect(suggested.map(\.note) == ["Review requested on GitHub", "From yesterday's incident"])
        #expect(suggested.allSatisfy { !model.isPicked($0) })
        #expect(model.rows(in: .added).map(\.title) == ["Answer the RFC comments"])
        #expect(model.planned == 3)
    }

    @Test func noSuggestionsMeansNoSuggestedGroup() {
        let model = PlanSheetModel(day: SheetSpecimens.day, carried: [], suggestions: [], usual: nil)
        #expect(model.rows(in: .suggested).isEmpty)
        #expect(!model.canStart)
    }

    @Test func theNoteCountsThePlanAndNamesTheUsualSize() {
        let usual = UsualRange(low: 3, median: 4, high: 5, days: 20)
        let model = PlanSheetModel(day: SheetSpecimens.day, carried: [], suggestions: Self.suggestions, usual: usual)
        #expect(model.countNote == "0 planned. You usually plan 3 to 5, and suggestions only join your plan if you pick them.")
        model.toggle("suggested-0")
        model.draft = "Write the notes"
        #expect(model.addDraft())
        #expect(model.countNote == "2 planned. You usually plan 3 to 5, and suggestions only join your plan if you pick them.")
        let single = PlanSheetModel(day: SheetSpecimens.day, carried: [], suggestions: [], usual: UsualRange(low: 4, median: 4, high: 4, days: 12))
        #expect(single.countNote == "0 planned. You usually plan 4, and suggestions only join your plan if you pick them.")
        // With no usual size yet, the sentence leaves it out rather than guessing.
        let learning = PlanSheetModel(day: SheetSpecimens.day, carried: [], suggestions: [], usual: nil)
        #expect(learning.countNote == "0 planned. Suggestions only join your plan if you pick them.")
    }

    @Test func moreThanSevenGetsAQuietNoteAndStillStarts() {
        let model = PlanSheetModel(day: SheetSpecimens.day, carried: [], suggestions: [], usual: nil)
        for index in 1...7 {
            model.draft = "Task \(index)"
            model.addDraft()
        }
        #expect(!model.showsQuietNote)
        model.draft = "Task 8"
        model.addDraft()
        #expect(model.showsQuietNote)
        #expect(model.canStart)
    }

    @Test func emptyFieldAddsNothingAndAddedRowsStayTicked() {
        let model = PlanSheetModel(day: SheetSpecimens.day, carried: [], suggestions: [], usual: nil)
        model.draft = "   "
        #expect(!model.addDraft())
        model.draft = "Write the notes"
        model.addDraft()
        let row = try! #require(model.rows(in: .added).first)
        model.toggle(row.id)
        #expect(model.isPicked(row))
        #expect(model.draft.isEmpty)
    }

    @Test func startTheDayCommitsCarriedThenSuggestedThenTyped() async throws {
        let home = Home()
        defer { home.remove() }
        let app = try await Self.make(home)
        let model = try #require(PlanSheetModel(app: app, suggestions: Self.suggestions))
        // Keep the second carried task only, pick the first suggestion, and leave a typed task in the field.
        model.toggle(try #require(model.rows(in: .carried).first?.id))
        model.toggle("suggested-0")
        model.draft = "Write the replay notes"
        #expect(await model.commit(app: app, sound: nil))
        await AppStateTests.settle(app)
        let context = try #require(app.context)
        #expect(context.committed)
        #expect(context.plan.filter { $0.status == .open }.map(\.title) == [
            "Prototype the ACME-000000 replay tool", "Answer the RFC comments", "Review the proof export PR", "Write the replay notes",
        ])
        // The carried task left unticked was dropped by the commit and is not part of today's plan.
        #expect(!context.plan.contains { $0.title == "Draft the idempotency ADR" })
        #expect(context.view.tasks.first { $0.title == "Draft the idempotency ADR" }?.status == .dropped)
    }

    @Test func nothingPickedDoesNotCommit() async throws {
        let home = Home()
        defer { home.remove() }
        let app = try await Self.make(home)
        let model = PlanSheetModel(day: app.today, carried: [], suggestions: Self.suggestions, usual: nil)
        #expect(!(await model.commit(app: app, sound: nil)))
        await AppStateTests.settle(app)
        #expect(app.context?.committed == false)
    }

    @Test func theKickerIsTheDateInTheLocale() {
        #expect(SheetDate.kicker(SheetSpecimens.day, locale: Locale(identifier: "en_GB")).contains("Thursday"))
        #expect(SheetDate.kicker(SheetSpecimens.day, locale: Locale(identifier: "en_GB")).contains("29 Oct"))
    }

    @Test func discreetTitlesReadTaskN() {
        #expect(SheetTitles(discreet: true)("Draft the ADR", index: 1) == "Task 2")
        #expect(SheetTitles()("Draft the ADR", index: 1) == "Draft the ADR")
    }
}

/// The wrap-up (docs/SPEC.md section 4.5): one question at a time, then the tiles, then the seal.
@MainActor @Suite struct WrapUpSheetTests {
    typealias Home = DayStoreLoaderTests.Home

    static let friday = LocalDate(year: 2026, month: 9, day: 18)!

    /// Monday 21 Sep with three open tasks and one done, and Friday 18 Sep left unsealed with two tasks, one done.
    static func make(_ home: Home) async throws -> AppState {
        let journal = try home.journal()
        for title in ["Ship retry budget for capture path", "Draft the idempotency ADR", "Prototype the replay tool"] {
            _ = try journal.planAdd(title: title, day: nil, estimateMin: nil, origin: .selfReported, actor: .cli)
        }
        let done = try journal.planAdd(title: "Review the RFC", day: nil, estimateMin: nil, origin: .selfReported, actor: .cli)
        _ = try journal.planResolve(taskID: done.id, status: .done, reason: nil, note: nil, links: [], actor: .cli)
        _ = try journal.log(LogRequest(text: "Reviewed the settlement batching RFC", kind: .reviewGiven), actor: .cli, origin: .selfReported)
        let fridayDone = try journal.planAdd(title: "Pair on the flaky ledger test", day: friday, estimateMin: nil, origin: .selfReported, actor: .cli)
        _ = try journal.planResolve(taskID: fridayDone.id, status: .done, reason: nil, note: nil, links: [], actor: .cli)
        _ = try journal.planAdd(title: "Prepare design review notes", day: friday, estimateMin: nil, origin: .selfReported, actor: .cli)
        let clock = DayStoreLoaderTests.FixedClock()
        let app = AppState(
            model: DayModel(loader: home.loader),
            writer: AppWriter(location: .found(home.roots), clock: clock, poster: AppWriterTests.CountingPoster()), clock: clock)
        await AppStateTests.settle(app)
        return app
    }

    static func today(_ app: AppState) throws -> WrapUpDay {
        let context = try #require(app.context)
        return try #require(WrapUpDay(context: context, today: app.today))
    }

    @Test func eachOpenTaskThenTheTilesThenReadyToClose() async throws {
        let home = Home()
        defer { home.remove() }
        let app = try await Self.make(home)
        let flow = WrapUpFlow(day: try Self.today(app))
        #expect(flow.open.map(\.title) == ["Ship retry budget for capture path", "Draft the idempotency ADR", "Prototype the replay tool"])
        #expect(flow.stepCount == 5)
        #expect(flow.step == .task(0))
        #expect(flow.taskKicker == "Wrap up, 3 left")
        #expect(flow.moveLabel == "Move to tomorrow")

        #expect(await flow.answer(.done, writer: app))
        #expect(flow.step == .task(1))
        #expect(flow.taskKicker == "Wrap up, 2 left")
        // Move asks for the reason first, on the same step of the bar.
        flow.move()
        #expect(flow.step == .reason(1))
        #expect(flow.stepIndex == 1)
        #expect(await flow.answer(.moved(.waitingOnSomeone), writer: app))
        #expect(flow.step == .task(2))
        #expect(await flow.answer(.dropped, writer: app))
        #expect(flow.step == .signals)
        #expect(flow.stepIndex == 3)
        #expect(await flow.continueFromSignals(writer: app))
        #expect(flow.step == .ready)
        #expect(flow.stepIndex == 4)

        await AppStateTests.settle(app)
        let plan = try #require(app.context?.plan)
        func task(_ title: String) -> PlanTask? { plan.first { $0.title == title } }
        #expect(task("Ship retry budget for capture path")?.status == .done)
        #expect(task("Draft the idempotency ADR")?.status == .slipped)
        #expect(task("Draft the idempotency ADR")?.reason == "waiting_on_someone")
        #expect(task("Prototype the replay tool")?.status == .dropped)
    }

    @Test func aRefusedAnswerStaysOnItsQuestion() async throws {
        let home = Home()
        defer { home.remove() }
        let app = try await Self.make(home)
        var day = try Self.today(app)
        day.plan[0].id = "missing"
        let flow = WrapUpFlow(day: day)
        #expect(!(await flow.answer(.done, writer: app)))
        #expect(flow.step == .task(0))
        #expect(flow.answers.isEmpty)
    }

    @Test func aTaskWhosePullRequestMergedSaysSo() {
        func task(_ id: String, _ key: String) -> PlanTask {
            PlanTask(
                id: id, day: SheetSpecimens.day.description, position: 0, title: "Ship \(key)",
                ticket: Ticket(key: key, class: .assigned), origin: .selfReported, plannedAt: "2026-09-22T09:00:00+05:30")
        }
        let day = WrapUpDay(
            date: SheetSpecimens.day, today: SheetSpecimens.day, plan: [task("a", "ACME-142"), task("b", "ACME-7")], items: 2,
            merged: ["ACME-142"])
        let flow = WrapUpFlow(day: day)
        #expect(flow.mergedNote == "Its pull request for ACME-142 merged today.")
    }

    @Test func noOpenTasksStartsAtTheTiles() {
        let day = WrapUpDay(date: SheetSpecimens.day, today: SheetSpecimens.day, plan: [], items: 3)
        let flow = WrapUpFlow(day: day)
        #expect(flow.step == .signals)
        #expect(flow.stepCount == 2)
    }

    @Test func tilesCountReadDashWhenUnsetAndLogTheirKinds() async throws {
        let home = Home()
        defer { home.remove() }
        let app = try await Self.make(home)
        let day = try Self.today(app)
        let flow = WrapUpFlow(day: WrapUpDay(date: day.date, today: day.today, plan: [], items: day.items))
        #expect(WrapUpSignal.allCases.map(flow.countText) == ["-", "-", "-", "-"])
        flow.tap(.meetingLed)
        flow.tap(.meetingLed)
        flow.setNote("Ran the incident review\nsecond line dropped", for: .incident)
        #expect(flow.countText(.meetingLed) == "2")
        #expect(flow.countText(.incident) == "1")
        #expect(flow.notes[.incident] == "Ran the incident review")
        flow.tap(.mentored)
        flow.clear(.mentored)
        #expect(flow.countText(.mentored) == "-")
        #expect(await flow.continueFromSignals(writer: app))
        #expect(flow.items == day.items + 3)

        await AppStateTests.settle(app)
        let found = try #require(app.context?.found)
        #expect(found.filter { $0.kind == .meetingLed }.count == 2)
        #expect(found.filter { $0.kind == .incidentHandled }.map(\.title) == ["Handled an incident"])
        #expect(found.filter { $0.kind == .incidentHandled }.first?.attrs["note"] == .string("Ran the incident review"))
        #expect(found.allSatisfy { $0.kind != .mentoring && $0.kind != .decisionChallenged })
    }

    @Test func theClosingSentence() {
        #expect(WrapUpFlow.closing(done: 4, planned: 5, items: 9) == "4 of 5 done, and 9 items logged.")
        #expect(WrapUpFlow.closing(done: 1, planned: 1, items: 1) == "1 of 1 done, and 1 item logged.")
        #expect(WrapUpFlow.closing(done: 0, planned: 2, items: 0) == "0 of 2 done, and no items logged.")
        #expect(WrapUpFlow.closing(done: 0, planned: 0, items: 3) == "Nothing was planned, and 3 items logged.")
    }

    @Test func theClosingSentenceCountsTheAnswers() async throws {
        let home = Home()
        defer { home.remove() }
        let app = try await Self.make(home)
        let flow = WrapUpFlow(day: try Self.today(app))
        await flow.answer(.done, writer: app)
        await flow.answer(.dropped, writer: app)
        await flow.answer(.done, writer: app)
        flow.tap(.decisionChallenged)
        await flow.continueFromSignals(writer: app)
        #expect(flow.closing == "3 of 4 done, and \(flow.day.items + 1) items logged.")
    }

    @Test func copyAndSealPutsTheStandupWithItsWitnessOnThePasteboard() async throws {
        let home = Home()
        defer { home.remove() }
        let app = try await Self.make(home)
        let flow = WrapUpFlow(day: WrapUpDay(date: app.today, today: app.today, plan: [], items: 1))
        await flow.continueFromSignals(writer: app)
        var copied: [String] = []
        let sealed = await flow.seal(copy: true, writer: app, pasteboard: { copied.append($0) })
        #expect(sealed?.day == app.today)
        #expect(flow.sealed != nil)
        #expect(copied.count == 1)
        #expect(copied.first?.split(separator: "\n").last?.hasPrefix("cadence ") == true)
        // A sealed flow does not seal again.
        #expect(await flow.seal(copy: true, writer: app, pasteboard: { copied.append($0) }) == nil)
        #expect(copied.count == 1)
    }

    @Test func sealOnlyCopiesNothing() async throws {
        let home = Home()
        defer { home.remove() }
        let app = try await Self.make(home)
        let flow = WrapUpFlow(day: WrapUpDay(date: app.today, today: app.today, plan: [], items: 1))
        await flow.continueFromSignals(writer: app)
        var copied: [String] = []
        #expect(await flow.seal(copy: false, writer: app, pasteboard: { copied.append($0) }) != nil)
        #expect(copied.isEmpty)
        await AppStateTests.settle(app)
        #expect(app.context?.view.day.sealedAt != nil)
    }

    @Test func yesterdayInItsGraceWindowSkipsTheTilesAndSealsThatDay() async throws {
        let home = Home()
        defer { home.remove() }
        let app = try await Self.make(home)
        let journal = try home.journal()
        let context = try journal.dayContext(on: Self.friday)
        let day = try #require(WrapUpDay(context: context, today: app.today))
        #expect(day.isYesterday)
        let flow = WrapUpFlow(day: day)
        let english = Locale.current.language.languageCode == .english
        #expect(flow.open.map(\.title) == ["Prepare design review notes"])
        #expect(flow.stepCount == 2)
        if english {
            #expect(flow.taskKicker == "Wrap up Friday, 1 left")
            #expect(flow.moveLabel == "Move to Monday")
            #expect(flow.sealLabel == "Seal Friday")
        }
        #expect(await flow.answer(.done, writer: app))
        #expect(flow.step == .ready)
        if english { #expect(flow.readyKicker == "Ready to close Friday") }
        #expect(flow.closing == "2 of 2 done, and no items logged.")
        #expect(WrapUpFlow.lateSeal == "This will show as sealed the next morning, on your log and in any proof.")
        var copied: [String] = []
        let sealed = await flow.seal(copy: true, writer: app, pasteboard: { copied.append($0) })
        #expect(sealed?.day == Self.friday)
        // Yesterday has no stand-up to copy, and today stays open.
        #expect(copied.isEmpty)
        await AppStateTests.settle(app)
        #expect(app.context?.view.day.sealedAt == nil)
        #expect(try journal.dayView(Self.friday).day.sealedAt != nil)
    }

    @Test func theSlipReasonsAreTheFourChips() {
        #expect(SlipReason.allCases.map(\.label) == ["Reprioritised", "Blocked", "Too big", "Waiting on someone"])
        #expect(WrapUpAnswer.moved(.tooBig).reason == "too_big")
        #expect(WrapUpAnswer.moved(.tooBig).status == .slipped)
        #expect(WrapUpFlow.reasonPrompt == "What happened? This helps your patterns, and it is never judged.")
        #expect(WrapUpFlow.copyHint == "A code only helps if it reaches someone else, so copying is the default.")
    }

    @Test func reduceMotionShowsOnlyTheEndState() {
        #expect(SealingView.duration(reduceMotion: true) == SealingView.hold)
        #expect(SealingView.duration(reduceMotion: false) == CadenceMotion.sweep.duration + SealingView.hold)
        #expect(CadenceMotion.sweep.duration == 1.4)
        #expect(SealingView.tempoPose == "blanket")
    }
}
