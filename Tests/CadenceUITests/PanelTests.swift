import AppKit
import CadenceCore
import Foundation
import SwiftUI
import Testing

@testable import CadenceUI

/// The menu-bar panel and the status item's menu (docs/SPEC.md sections 4.1 and 4.2).
@MainActor @Suite struct PanelTests {
    static let day = LocalDate(year: 2026, month: 10, day: 29)!
    static let gb = Locale(identifier: "en_GB")

    static func tasks(_ statuses: [TaskStatus]) -> [PlanTask] {
        statuses.enumerated().map { index, status in
            PlanTask(
                id: "t\(index)", day: day.description, position: Int64(index), title: "ACME task \(index + 1)",
                origin: .selfReported, status: status, plannedAt: "2026-10-29T09:05:00+05:30")
        }
    }

    static func story(_ edit: (inout DayStory.Input) -> Void) -> DayStory {
        var input = DayStory.Input(date: day)
        input.countedWorkdays = 18
        input.usualByNow = 6...9
        edit(&input)
        return DayStory(input)
    }

    static func content(_ story: DayStory, _ edit: (inout PanelInput) -> Void = { _ in }) -> PanelContent {
        var input = PanelInput(story: story, date: day)
        edit(&input)
        return PanelContent(input, locale: gb)
    }

    // MARK: the panel table

    @Test func theActionForEveryDayState() {
        let expected: [DayStory.State: (none: PanelAction?, some: PanelAction?)] = [
            .storeProblem: (.fix, .fix),
            .paused: (nil, nil),
            .sealed: (.lastWeekRecap, .lastWeekRecap),
            .editedAfterWrapUp: (.lastWeekRecap, .lastWeekRecap),
            .yesterdayOpen: (.planToday, nil),
            .closedUnsealed: (.planDay, nil),
            .leave: (nil, nil), .sick: (nil, nil), .holiday: (nil, nil), .weekend: (nil, nil),
            .firstRun: (.finishSetup, .finishSetup),
            .firstSync: (.planDay, nil), .learning: (.planDay, nil), .sourceBehind: (.planDay, nil), .onCall: (.planDay, nil),
            .wrapUpDue: (.wrapUp(open: 0), .wrapUp(open: 2)),
            .nothingLogged: (.sealAsEmpty, .sealAsEmpty),
            .planSettled: (.wrapUp(open: 0), .wrapUp(open: 2)),
            .morning: (.planDay, nil), .planned: (.planDay, nil),
            .inRhythm: (.planDay, nil), .moreThanUsual: (.planDay, nil), .fewerThanUsual: (.planDay, nil),
        ]
        for state in DayStory.State.allCases {
            let want = expected[state]
            #expect(want != nil, "no expectation for \(state)")
            #expect(PanelAction.choose(state, planned: 0, open: 0) == want?.none, "\(state) without a plan")
            #expect(PanelAction.choose(state, planned: 5, open: 2) == want?.some, "\(state) with a plan")
        }
    }

    @Test func aPassedReminderOffersWrapUpWhereALearningOrOnCallDayWouldNot() {
        #expect(PanelAction.choose(.learning, planned: 3, open: 1, reminderPassed: true) == .wrapUp(open: 1))
        #expect(PanelAction.choose(.onCall, planned: 3, open: 0, reminderPassed: true) == .wrapUp(open: 0))
        #expect(PanelAction.choose(.learning, planned: 3, open: 1) == nil)
        #expect(PanelAction.choose(.leave, planned: 3, open: 1, reminderPassed: true) == nil)
        #expect(PanelAction.choose(.paused, planned: 3, open: 1, reminderPassed: true) == nil)
    }

    @Test func actionTitlesReadAsTheSpecWritesThem() {
        #expect(PanelAction.wrapUp(open: 2).title == "Wrap up, 2 open")
        #expect(PanelAction.wrapUp(open: 0).title == "Wrap up")
        #expect(PanelAction.sealAsEmpty.title == "Seal as empty")
        #expect(PanelAction.planToday.title == "Plan today")
        #expect(PanelAction.planDay.title == "Plan your day")
        #expect(PanelAction.finishSetup.title == "Finish setting up")
        #expect(PanelAction.lastWeekRecap.title == "See last week's recap")
        #expect(PanelAction.fix.title == "Open Cadence to fix")
        for action in [PanelAction.wrapUp(open: 2), .sealAsEmpty, .planToday, .planDay, .finishSetup, .lastWeekRecap, .fix] {
            #expect(CopyRules.allows(action.title))
        }
    }

    @Test func wrapUpCountsTheHeldTickAsDone() {
        let c = Self.content(Self.story { $0.wrapUpReminder = "17:30"; $0.planned = 3; $0.items = 4 }) {
            $0.plan = Self.tasks([.done, .open, .open])
            $0.held = "t1"
        }
        #expect(c.action == .wrapUp(open: 1))
    }

    // MARK: the short line

    @Test func theShortLineForEachCase() {
        let started = Self.content(Self.story { $0.items = 7 }) {
            $0.items = 7
            $0.startedAt = "09:41"
        }
        #expect(started.line == "7 items logged since 09:41.")
        let one = Self.content(Self.story { $0.items = 1 }) {
            $0.items = 1
            $0.startedAt = "09:41"
        }
        #expect(one.line == "1 item logged since 09:41.")
        let sealed = Self.content(Self.story { $0.sealedAt = "18:12" }) {
            $0.items = 8
            $0.sealedAt = "18:12"
            $0.startedAt = "09:41"
        }
        #expect(sealed.line == "Sealed at 18:12, 8 items logged.")
        #expect(Self.content(Self.story { $0.dayOff = .holiday }).line == "Nothing expected today.")
        #expect(Self.content(Self.story { $0.dayOff = .weekend }).line == "Nothing expected today.")
        #expect(Self.content(Self.story { $0.storeProblem = true }).line == "Nothing can be saved until this is fixed.")
        #expect(Self.content(Self.story { _ in }).line == "Thursday 29 Oct.")
    }

    @Test func theNoteForPausedABehindSourceAndAFailedWrite() {
        let paused = Self.content(Self.story { $0.paused = true }) { $0.pausedUntil = "15:00" }
        #expect(paused.note == .init(text: "Capture paused until 15:00.", button: .resume))
        #expect(Self.content(Self.story { $0.paused = true }).note?.text == "Capture paused.")
        let behind = DayStory.Behind(source: "GitHub", lastSync: "13:40")
        let stale = Self.content(Self.story { $0.behind = behind }) { $0.behind = behind }
        #expect(stale.note == .init(text: "GitHub last synced at 13:40.", button: .sources))
        #expect(Self.content(Self.story { $0.items = 3 }).note == nil)
        let failed = Self.content(Self.story { _ in }) { $0.issue = "Cadence cannot read its store" }
        #expect(failed.note?.button == .openCadence)
    }

    // MARK: rows

    @Test func sixRowsInPlanOrderThenNMore() {
        let c = Self.content(Self.story { $0.planned = 8; $0.items = 3 }) {
            $0.plan = Self.tasks([.done, .open, .dropped, .open, .slipped, .open, .open, .open])
        }
        guard case .plan(let rows, let more, _, let sealed) = c.area else {
            Issue.record("expected the plan")
            return
        }
        #expect(rows.map(\.id) == ["t0", "t1", "t2", "t3", "t4", "t5"])
        // Done rows stay in place, and only open rows can be ticked.
        #expect(rows.map(\.status) == [.done, .open, .dropped, .open, .slipped, .open])
        #expect(rows.map(\.tickable) == [false, true, false, true, false, true])
        #expect(more == 2)
        #expect(!sealed)
        #expect(c.area.moreText == "2 more in Today")
        #expect(c.area.title == "Today's plan")
    }

    @Test func noMoreRowAtSixOrFewer() {
        let c = Self.content(Self.story { $0.planned = 6; $0.items = 3 }) { $0.plan = Self.tasks(Array(repeating: .open, count: 6)) }
        #expect(c.area.moreText == nil)
    }

    @Test func aSealedPlanIsReadOnly() {
        let c = Self.content(Self.story { $0.sealedAt = "18:12"; $0.planned = 2; $0.resolved = 1 }) {
            $0.plan = Self.tasks([.done, .open])
        }
        guard case .plan(let rows, _, _, let sealed) = c.area else {
            Issue.record("expected the plan")
            return
        }
        #expect(sealed)
        #expect(c.area.title == "Plan, sealed")
        #expect(rows.allSatisfy { !$0.tickable })
    }

    @Test func withoutAPlanCarriedThenEnjoyThenNoPlan() {
        let carried = Self.tasks([.open, .open]).map { task in
            var t = task
            t.origin = .carried
            return t
        }
        let morning = Self.content(Self.story { $0.carried = 2 }) { $0.carried = carried }
        guard case .carried(let rows) = morning.area else {
            Issue.record("expected carried tasks")
            return
        }
        #expect(rows.count == 2)
        #expect(rows.allSatisfy { !$0.tickable })
        #expect(morning.area.title == "Carried from yesterday")

        let leave = Self.content(Self.story { $0.dayOff = .leave }) { $0.carried = carried }
        #expect(leave.area == .enjoy)
        #expect(Self.content(Self.story { $0.wrapUpReminder = "17:30" }).area == .noPlan)
        #expect(Self.content(Self.story { $0.storeProblem = true }).area == PanelContent.Area.none)
    }

    // MARK: the count

    @Test func theCountWithAndWithoutAHeldTick() {
        let plain = Self.content(Self.story { $0.planned = 5; $0.items = 3 }) { $0.plan = Self.tasks([.done, .done, .open, .open, .open]) }
        guard case .plan(_, _, let count, _) = plain.area else {
            Issue.record("expected the plan")
            return
        }
        #expect(count.text == "2 of 5")
        let held = Self.content(Self.story { $0.planned = 5; $0.items = 3 }) {
            $0.plan = Self.tasks([.done, .done, .open, .open, .open])
            $0.held = "t2"
        }
        guard case .plan(let rows, _, let heldCount, _) = held.area else {
            Issue.record("expected the plan")
            return
        }
        #expect(heldCount.text == "Logged, 3 of 5")
        #expect(rows[2].status == .done)
        #expect(rows[2].held)
    }

    // MARK: log field, day off, Tempo

    @Test func theLogFieldIsOffOnlyOnAStoreProblem() {
        let problem = Self.content(Self.story { $0.storeProblem = true })
        #expect(!problem.logEnabled)
        #expect(PanelContent.logOffPlaceholder == "Logging is off until the log is fixed")
        #expect(Self.content(Self.story { $0.sealedAt = "18:12" }).logEnabled)
    }

    @Test func dayOffIsHiddenOnDaysOffSealedDaysAndErrors() {
        #expect(!Self.content(Self.story { $0.dayOff = .sick }).showsDayOff)
        #expect(!Self.content(Self.story { $0.dayOff = .weekend }).showsDayOff)
        #expect(!Self.content(Self.story { $0.sealedAt = "18:12" }).showsDayOff)
        #expect(!Self.content(Self.story { $0.sealedAt = "18:12"; $0.lateAdditions = 1 }).showsDayOff)
        #expect(!Self.content(Self.story { $0.storeProblem = true }).showsDayOff)
        #expect(Self.content(Self.story { $0.items = 3 }).showsDayOff)
        #expect(Self.content(Self.story { $0.paused = true }).showsDayOff)
    }

    @Test func everyPanelStringFollowsTheCopyRules() {
        let strings = [
            PanelContent.enjoyText, PanelContent.workingAfterAll, PanelContent.noPlanText, PanelContent.logPlaceholder,
            PanelContent.loggedPlaceholder, PanelContent.logOffPlaceholder,
        ]
        for text in strings { #expect(CopyRules.allows(text)) }
    }

    // MARK: discreet titles, through AppState

    @Test func discreetTitlesComeFromAppState() async throws {
        let home = AppStateTests.Home()
        defer { home.remove() }
        let app = try await AppStateTests.make(home)
        #expect(PanelInput.from(app, pausedUntil: nil).plan.map(\.title) == ["Write the ADR", "Review the RFC"])
        app.discreet = true
        let input = PanelInput.from(app, pausedUntil: nil)
        #expect(input.plan.map(\.title) == ["Task 1", "Task 2"])
        #expect(!input.showsTempo)
    }

    @Test func aTickHeldInAppStateReadsAsLoggedInThePanel() async throws {
        let home = AppStateTests.Home()
        defer { home.remove() }
        let app = try await AppStateTests.make(home)
        let task = try #require(app.context?.plan.first)
        app.tick(task)
        let content = PanelContent(PanelInput.from(app, pausedUntil: nil))
        guard case .plan(_, _, let count, _) = content.area else {
            Issue.record("expected the plan")
            return
        }
        #expect(count.text == "Logged, 1 of 2")
        app.undoTick()
    }

    // MARK: the status item's menu

    @Test func theMenuItemsPerState() {
        func menu(_ story: DayStory, paused: Bool = false, _ edit: (inout PanelInput) -> Void = { _ in }) -> [StatusMenuItem] {
            StatusMenuItem.items(Self.content(story, edit), paused: paused, pauseUntil: "15:00")
        }
        let tail: [StatusMenuItem] = [.separator, .settings, .quit]

        #expect(
            menu(Self.story { $0.carried = 1 })
                == [.logSomething, .nextStep(.planDay), .openCadence, .separator, .pause(until: "15:00"), .notWorkingToday] + tail)
        #expect(
            menu(Self.story { $0.wrapUpReminder = "17:30"; $0.planned = 2; $0.items = 2 }) { $0.plan = Self.tasks([.open, .done]) }
                == [.logSomething, .nextStep(.wrapUp(open: 1)), .openCadence, .separator, .pause(until: "15:00"), .notWorkingToday]
                + tail)
        #expect(
            menu(Self.story { $0.items = 5; $0.planned = 2 }) { $0.plan = Self.tasks([.open, .done]) }
                == [.logSomething, .openCadence, .separator, .pause(until: "15:00"), .notWorkingToday] + tail)
        #expect(
            menu(Self.story { $0.paused = true }, paused: true) == [.logSomething, .openCadence, .separator, .resume, .notWorkingToday] + tail)
        #expect(menu(Self.story { $0.dayOff = .leave }) == [.logSomething, .openCadence, .separator, .pause(until: "15:00")] + tail)
        #expect(menu(Self.story { $0.sealedAt = "18:12" }) == [.logSomething, .openCadence, .separator, .pause(until: "15:00")] + tail)
        #expect(menu(Self.story { $0.storeProblem = true }) == [.openCadence] + tail)
        #expect(menu(Self.story { $0.previous = .init(date: Self.day.adding(days: -1), graceOpen: true, sealedBefore: 3) }).contains(.nextStep(.planToday)))
    }

    @Test func menuTitlesReadAsTheSpecWritesThem() {
        #expect(StatusMenuItem.logSomething.title == "Log something")
        #expect(StatusMenuItem.nextStep(.wrapUp(open: 2)).title == "Wrap up")
        #expect(StatusMenuItem.nextStep(.planDay).title == "Plan your day")
        #expect(StatusMenuItem.openCadence.title == "Open Cadence")
        #expect(StatusMenuItem.pause(until: "15:00").title == "Pause capture until 15:00")
        #expect(StatusMenuItem.resume.title == "Resume capture")
        #expect(StatusMenuItem.notWorkingToday.title == "Not working today")
        #expect(StatusMenuItem.settings.title == "Settings\u{2026}")
        #expect(StatusMenuItem.quit.title == "Quit Cadence")
        #expect(StatusMenuItem.daysOff.map(\.1) == ["Leave", "Sick", "Holiday"])
    }

    @Test func thePauseEndsOnTheNextWholeHourAtLeastAnHourAway() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
        let at = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 29, hour: 13, minute: 40)))
        let end = CapturePause.suggestedEnd(after: at, calendar: calendar)
        #expect(calendar.dateComponents([.hour, .minute], from: end) == DateComponents(hour: 15, minute: 0))
    }

    // MARK: open time

    /// The panel is built once and kept; opening it is placing and showing a laid-out view (section 4.2: under 100 ms).
    @Test func aWarmPanelOpensInUnder100Milliseconds() throws {
        let content = Self.content(Self.story { $0.planned = 7; $0.items = 8 }) {
            $0.plan = Self.tasks([.done, .done, .open, .open, .open, .open, .open])
            $0.startedAt = "09:41"
        }
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: CadenceSize.panelWidth, height: CadenceSize.panelWidth),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        let hosting = NSHostingController(rootView: PanelCard(content: content))
        hosting.sizingOptions = [.preferredContentSize]
        panel.contentViewController = hosting
        panel.setContentSize(hosting.view.fittingSize)
        panel.layoutIfNeeded()

        var samples: [Double] = []
        for _ in 0..<5 {
            let start = CACurrentMediaTime()
            panel.setFrameTopLeftPoint(NSPoint(x: 200, y: 800))
            panel.orderFrontRegardless()
            panel.displayIfNeeded()
            samples.append((CACurrentMediaTime() - start) * 1000)
            panel.orderOut(nil)
        }
        let worst = samples.max() ?? 0
        print("panel open, warm: \(samples.map { String(format: "%.1f", $0) }.joined(separator: ", ")) ms")
        #expect(worst < 100)
    }

    /// The panel and Today speak a task's state with the same words.
    @Test func taskStatusWordsAreShared() {
        #expect(TaskWords.status(.open) == "open")
        #expect(TaskWords.status(.moved) == "open")
        #expect(TaskWords.status(.done) == "done")
        #expect(TaskWords.status(.slipped) == "slipped")
        #expect(TaskWords.status(.dropped) == "dropped")
    }
}
