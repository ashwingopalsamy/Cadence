import CadenceCore
import Foundation
import Testing

@testable import CadenceUI

/// What the app tells you and when (docs/SPEC.md section 4.7): the copy, counts instead of titles, the seven workdays
/// ahead, and what each button does. 2026-09-21 is a Monday.
@Suite struct NotificationPlanTests {
    static let kolkata = TimeZone(identifier: "Asia/Kolkata")!
    static func at(_ text: String) -> Date { Timestamp.parse(text)! }
    static func day(_ text: String) -> LocalDate { LocalDate(text)! }

    static func facts(
        day: String = "2026-09-24", committed: Bool = false, sealed: Bool = false, carried: [String]? = ["Write ADR", "Review RFC"],
        open: [String]? = ["Write ADR", "Review RFC"], items: Int? = 7, reviews: Int? = 1
    ) -> NotificationFacts {
        NotificationFacts(
            day: Self.day(day), committed: committed, sealed: sealed, carried: carried, open: open, items: items,
            reviewsWaiting: reviews)
    }

    static func input(
        now: String = "2026-09-24T09:02:00+05:30", declared: [LocalDate: DayKind] = [:], wrap: [String] = ["17:30"],
        showTitles: Bool = false, facts: NotificationFacts? = nil, snoozed: [PlannedNotification] = [],
        skipped: Set<LocalDate> = [], workdays: Set<Weekday> = [.mon, .tue, .wed, .thu, .fri]
    ) -> NotificationInput {
        NotificationInput(
            now: at(now), zone: kolkata, rules: DayRules(workdays: workdays, boundary: .standard), declared: declared,
            reminders: [Config.Reminder(kind: .plan, after: "dayStart+2m")] + wrap.map { Config.Reminder(kind: .wrap, at: $0) },
            showTitles: showTitles, facts: facts, snoozed: snoozed, skippedPlanDays: skipped)
    }

    // MARK: The copy of section 4.7

    @Test func theCategoriesAndTheirButtonsAreThoseOfTheSpec() {
        #expect(NotificationCategory.allCases.map(\.rawValue) == ["PLAN", "WRAP", "INBOX", "SOURCE"])
        #expect(NotificationAction.actions(for: .plan).map(\.title) == ["Plan now", "In 30 min", "Skip today"])
        #expect(NotificationAction.actions(for: .wrap).map(\.title) == ["Wrap up", "In 30 min"])
        #expect(NotificationAction.actions(for: .source).map(\.title) == ["Open Sources"])
        #expect(NotificationAction.actions(for: .inbox).isEmpty)
        // Every identifier is unique, so a reply names exactly one button.
        #expect(Set(NotificationAction.allCases.map(\.rawValue)).count == NotificationAction.allCases.count)
    }

    @Test func thePlanPromptReadsAsInTheSpec() throws {
        let prompt = try #require(NotificationPlan.planPrompt(Self.input(facts: Self.facts())))
        #expect(prompt.title == "Plan Thursday")
        #expect(prompt.body == "2 carried, and 1 review waiting on you")
        #expect(prompt.category == .plan)
        #expect(prompt.day == Self.day("2026-09-24"))
        #expect(prompt.fireAt == nil)  // it is delivered when the clock says so
    }

    @Test func thePlanPromptSaysOnlyWhatItKnows() throws {
        func body(carried: [String]?, reviews: Int?) throws -> String {
            try #require(NotificationPlan.planPrompt(Self.input(facts: Self.facts(carried: carried, reviews: reviews)))).body
        }
        #expect(try body(carried: ["A", "B"], reviews: 2) == "2 carried, and 2 reviews waiting on you")
        #expect(try body(carried: ["A"], reviews: nil) == "1 carried")
        #expect(try body(carried: [], reviews: 1) == "1 review waiting on you")
        #expect(try body(carried: [], reviews: 0) == "Nothing carried over.")
        // Unknown is not zero: with neither known there is no count to state.
        #expect(try body(carried: nil, reviews: nil) == "Nothing carried over.")
    }

    @Test func theWrapReminderReadsAsInTheSpec() throws {
        let input = Self.input(facts: Self.facts())
        let wrap = try #require(NotificationPlan.wrapReminders(input).first)
        #expect(wrap.title == "Wrap up Thursday, 17:30")
        #expect(wrap.body == "2 tasks open, and 7 items logged")
        #expect(wrap.category == .wrap)
        #expect(wrap.fireAt == Self.at("2026-09-24T17:30:00+05:30"))
    }

    @Test func theWrapReminderCountsOneAndZeroPlainly() throws {
        func body(open: [String]?, items: Int?) throws -> String {
            try #require(NotificationPlan.wrapReminders(Self.input(facts: Self.facts(open: open, items: items))).first).body
        }
        #expect(try body(open: ["A"], items: 1) == "1 task open, and 1 item logged")
        #expect(try body(open: [], items: 0) == "0 tasks open, and 0 items logged")
        #expect(try body(open: ["A", "B"], items: nil) == "2 tasks open")
        #expect(try body(open: nil, items: 3) == "3 items logged")
        #expect(try body(open: nil, items: nil) == NotificationPlan.unknownCountsBody)
    }

    @Test func theSourceNoticeReadsAsInTheSpec() throws {
        let notice = try #require(NotificationPlan.sourceBehind(source: "GitHub", hours: 3))
        #expect(notice.title == "GitHub has not synced for 3 hours")
        #expect(notice.body == "Everything else keeps working.")
        #expect(notice.category == .source)
        #expect(notice.fireAt == nil)
        #expect(NotificationPlan.sourceBehind(source: "GitHub", hours: 2) == nil)
        #expect(try #require(NotificationPlan.sourceBehind(source: "GitHub", hours: 26)).title == "GitHub has not synced for 26 hours")
    }

    @Test func hoursBehindCountsWholeHoursSinceTheLastSync() {
        let last = Self.at("2026-09-24T10:00:00+05:30")
        #expect(NotificationPlan.hoursBehind(since: last, now: Self.at("2026-09-24T12:59:59+05:30")) == 2)
        #expect(NotificationPlan.hoursBehind(since: last, now: Self.at("2026-09-24T13:00:00+05:30")) == 3)
        #expect(NotificationPlan.hoursBehind(since: last, now: Self.at("2026-09-24T09:00:00+05:30")) == 0)
    }

    // MARK: Counts, not titles

    @Test func titlesNeverAppearUnlessTheSettingIsOn() throws {
        let secret = ["Draft the ACME-4821 settlement note", "Review the ACME-9 RFC"]
        let facts = Self.facts(carried: secret, open: secret)
        let off = Self.input(showTitles: false, facts: facts)
        let texts = [
            try #require(NotificationPlan.planPrompt(off)).body, try #require(NotificationPlan.wrapReminders(off).first).body,
        ]
        for text in texts {
            #expect(!text.contains("ACME"))
            #expect(!text.contains("settlement"))
            #expect(!text.contains("("))
        }
    }

    @Test func withTheSettingOnTitlesFollowTheCount() throws {
        let facts = Self.facts(carried: ["Write ADR", "Review RFC"], open: ["Write ADR"])
        let on = Self.input(showTitles: true, facts: facts)
        #expect(try #require(NotificationPlan.planPrompt(on)).body == "2 carried (Write ADR and Review RFC), and 1 review waiting on you")
        #expect(try #require(NotificationPlan.wrapReminders(on).first).body == "1 task open (Write ADR), and 7 items logged")
    }

    @Test func titlesAreListedBriefly() throws {
        func body(_ titles: [String]) throws -> String {
            try #require(NotificationPlan.wrapReminders(Self.input(showTitles: true, facts: Self.facts(open: titles, items: 2))).first).body
        }
        #expect(try body(["A", "B", "C", "D"]) == "4 tasks open (A, B and 2 more), and 2 items logged")
        #expect(try body(["A", "B", "C"]) == "3 tasks open (A, B and 1 more), and 2 items logged")
        // A long title is cut, and a line break cannot reach a banner.
        let long = String(repeating: "x", count: 80)
        let cut = try body([long])
        #expect(cut == "1 task open (\(String(repeating: "x", count: 39))\u{2026}), and 2 items logged")
        #expect(try body(["First line\nsecond line"]) == "1 task open (First line second line), and 2 items logged")
    }

    @Test func nothingMentionsTheStreakOrBreaksTheCopyRules() throws {
        let titles = ["Write ADR", "Review RFC", "Ship it"]
        for showTitles in [false, true] {
            for facts in [Self.facts(carried: titles, open: titles), Self.facts(carried: [], open: [], items: 0, reviews: 0), Self.facts(carried: nil, open: nil, items: nil, reviews: nil)] {
                let input = Self.input(showTitles: showTitles, facts: facts)
                var all = NotificationPlan.wrapReminders(input)
                all += [NotificationPlan.planPrompt(input), NotificationPlan.sourceBehind(source: "GitHub", hours: 5)].compactMap { $0 }
                all += [NotificationPlan.snooze(.plan, day: facts.day, input: input), NotificationPlan.snooze(.wrap, day: facts.day, input: input)]
                    .compactMap { $0 }
                #expect(!all.isEmpty)
                for item in all {
                    for text in [item.title, item.body] {
                        #expect(!text.lowercased().contains("streak"), "\(text)")
                        #expect(CopyRules.allows(text), "\(text)")
                    }
                }
            }
        }
    }

    // MARK: Seven workdays ahead

    @Test func theNextSevenWorkdaysSkipTheWeekend() {
        let days = NotificationPlan.workdays(
            from: Self.day("2026-09-21"), count: 7, rules: DayRules(), declared: [:])
        #expect(days.map(\.description) == ["2026-09-21", "2026-09-22", "2026-09-23", "2026-09-24", "2026-09-25", "2026-09-28", "2026-09-29"])
    }

    @Test func leaveAndHolidaysAreSkippedAndTheWindowReachesFurther() {
        let declared: [LocalDate: DayKind] = [
            Self.day("2026-09-23"): .leavePlanned, Self.day("2026-09-24"): .leaveUnplanned, Self.day("2026-09-28"): .holiday,
        ]
        let days = NotificationPlan.workdays(from: Self.day("2026-09-21"), count: 7, rules: DayRules(), declared: declared)
        #expect(days.map(\.description) == ["2026-09-21", "2026-09-22", "2026-09-25", "2026-09-29", "2026-09-30", "2026-10-01", "2026-10-02"])
        // A weekend declared a workday counts, and a configured sixth workday too.
        let saturday: [LocalDate: DayKind] = [Self.day("2026-09-26"): .workday]
        #expect(NotificationPlan.workdays(from: Self.day("2026-09-25"), count: 2, rules: DayRules(), declared: saturday).map(\.description) == ["2026-09-25", "2026-09-26"])
        let six = DayRules(workdays: [.mon, .tue, .wed, .thu, .fri, .sat])
        #expect(NotificationPlan.workdays(from: Self.day("2026-09-25"), count: 2, rules: six, declared: [:]).map(\.description) == ["2026-09-25", "2026-09-26"])
    }

    @Test func aConfigurationWithNoWorkdayAtAllSchedulesNothingAndEnds() {
        let none = DayRules(workdays: [])
        #expect(NotificationPlan.workdays(from: Self.day("2026-09-21"), count: 7, rules: none, declared: [:]).isEmpty)
    }

    @Test func oneWrapRequestPerWorkdayAheadAndTime() {
        let input = Self.input(now: "2026-09-21T09:00:00+05:30", wrap: ["16:00", "17:30"])
        let planned = NotificationPlan.wrapReminders(input)
        #expect(planned.count == 14)
        #expect(Set(planned.map(\.id)).count == 14)
        #expect(planned.first?.id == "wrap.2026-09-21.16:00")
        #expect(planned.last?.id == "wrap.2026-09-29.17:30")
        #expect(planned.map(\.fireAt) == planned.map(\.fireAt).sorted { ($0 ?? .distantPast) < ($1 ?? .distantPast) })
        #expect(planned.allSatisfy { $0.category == .wrap && $0.fireAt != nil })
    }

    @Test func aLeaveDayHasNoWrapReminderAndNeitherDoesAHoliday() {
        let declared: [LocalDate: DayKind] = [Self.day("2026-09-22"): .leavePlanned, Self.day("2026-09-23"): .holiday]
        let planned = NotificationPlan.wrapReminders(Self.input(now: "2026-09-21T09:00:00+05:30", declared: declared))
        let days = Set(planned.compactMap(\.day).map(\.description))
        #expect(!days.contains("2026-09-22") && !days.contains("2026-09-23"))
        #expect(days.contains("2026-09-21") && days.contains("2026-09-24"))
    }

    @Test func aTimePassedTodayIsNotScheduledAndTomorrowsStay() {
        let input = Self.input(now: "2026-09-24T18:00:00+05:30", wrap: ["16:00", "17:30", "18:30"])
        let planned = NotificationPlan.wrapReminders(input)
        let today = planned.filter { $0.day == Self.day("2026-09-24") }
        #expect(today.map(\.id) == ["wrap.2026-09-24.18:30"])
        #expect(planned.contains { $0.id == "wrap.2026-09-25.16:00" })
    }

    @Test func aSealedDayHasNoMoreReminders() {
        let sealed = Self.input(now: "2026-09-24T16:00:00+05:30", facts: Self.facts(sealed: true))
        let days = NotificationPlan.wrapReminders(sealed).compactMap(\.day)
        #expect(!days.contains(Self.day("2026-09-24")))
        #expect(days.contains(Self.day("2026-09-25")))
    }

    @Test func onlyTodayCarriesCountsAndTheRestAreAskedForPlainly() {
        let planned = NotificationPlan.wrapReminders(Self.input(facts: Self.facts()))
        #expect(planned.first?.body == "2 tasks open, and 7 items logged")
        let tomorrow = planned.filter { $0.day != Self.day("2026-09-24") }
        #expect(!tomorrow.isEmpty)
        #expect(tomorrow.allSatisfy { $0.body == NotificationPlan.unknownCountsBody })
        // Facts read for another day are not today's.
        let stale = Self.input(facts: Self.facts(day: "2026-09-23"))
        #expect(NotificationPlan.wrapReminders(stale).first?.body == NotificationPlan.unknownCountsBody)
    }

    @Test func aTimeBeforeTheBoundaryIsTheTailOfTheWorkday() {
        let planned = NotificationPlan.wrapReminders(Self.input(now: "2026-09-24T20:00:00+05:30", wrap: ["02:00"]))
        #expect(planned.first?.id == "wrap.2026-09-24.02:00")
        #expect(planned.first?.fireAt == Self.at("2026-09-25T02:00:00+05:30"))
    }

    @Test func aTriggerNamesTheCalendarTimeInTheProfileZone() throws {
        let wrap = try #require(NotificationPlan.wrapReminders(Self.input()).first)
        let parts = try #require(wrap.dateComponents)
        #expect(parts.year == 2026 && parts.month == 9 && parts.day == 24)
        #expect(parts.hour == 17 && parts.minute == 30 && parts.second == 0)
        #expect(parts.timeZone == Self.kolkata)
        #expect(NotificationPlan.planPrompt(Self.input(facts: Self.facts()))?.dateComponents == nil)
    }

    // MARK: The plan prompt

    @Test func thePlanPromptWaitsForAPlanToBeNeeded() {
        let day = Self.day("2026-09-24")
        #expect(NotificationPlan.planPrompt(Self.input(facts: Self.facts())) != nil)
        #expect(NotificationPlan.planPrompt(Self.input(facts: Self.facts(committed: true))) == nil)
        #expect(NotificationPlan.planPrompt(Self.input(facts: Self.facts(sealed: true))) == nil)
        #expect(NotificationPlan.planPrompt(Self.input(facts: Self.facts(), skipped: [day])) == nil)
        #expect(NotificationPlan.planPrompt(Self.input(facts: nil)) == nil)
        // The wrong day's facts, such as just after the boundary, say nothing about today.
        #expect(NotificationPlan.planPrompt(Self.input(facts: Self.facts(day: "2026-09-23"))) == nil)
        // Leave, a holiday and an undeclared weekend never prompt.
        for kind in [DayKind.leavePlanned, .leaveUnplanned, .holiday] {
            #expect(NotificationPlan.planPrompt(Self.input(declared: [day: kind], facts: Self.facts())) == nil, "\(kind)")
        }
        let saturday = Self.input(now: "2026-09-26T09:02:00+05:30", facts: Self.facts(day: "2026-09-26"))
        #expect(NotificationPlan.planPrompt(saturday) == nil)
    }

    // MARK: In 30 min

    @Test func inThirtyMinutesIsOneNotificationThirtyMinutesOn() throws {
        let input = Self.input(now: "2026-09-24T09:02:00+05:30", facts: Self.facts())
        let plan = try #require(NotificationPlan.snooze(.plan, day: Self.day("2026-09-24"), input: input))
        #expect(plan.id == "plan.2026-09-24.later")
        #expect(plan.title == "Plan Thursday")
        #expect(plan.body == "2 carried, and 1 review waiting on you")
        #expect(plan.fireAt == Self.at("2026-09-24T09:32:00+05:30"))
        #expect(plan.category == .plan)

        let late = Self.input(now: "2026-09-24T17:31:20+05:30", facts: Self.facts())
        let wrap = try #require(NotificationPlan.snooze(.wrap, day: Self.day("2026-09-24"), input: late))
        #expect(wrap.id == "wrap.2026-09-24.later")
        // The title carries the time it will arrive.
        #expect(wrap.title == "Wrap up Thursday, 18:01")
        #expect(wrap.body == "2 tasks open, and 7 items logged")
        #expect(wrap.fireAt == Self.at("2026-09-24T18:01:20+05:30"))
    }

    @Test func aSecondPressReplacesTheFirstNotAddsAnother() throws {
        let first = try #require(NotificationPlan.snooze(.plan, day: Self.day("2026-09-24"), input: Self.input(facts: Self.facts())))
        let later = Self.input(now: "2026-09-24T09:33:00+05:30", facts: Self.facts())
        let second = try #require(NotificationPlan.snooze(.plan, day: Self.day("2026-09-24"), input: later))
        #expect(first.id == second.id)
        #expect(second.fireAt == Self.at("2026-09-24T10:03:00+05:30"))
    }

    @Test func thereIsNothingToPutOffOnceThePlanIsMadeOrTheDayIsSealed() {
        let day = Self.day("2026-09-24")
        #expect(NotificationPlan.snooze(.plan, day: day, input: Self.input(facts: Self.facts(committed: true))) == nil)
        #expect(NotificationPlan.snooze(.plan, day: day, input: Self.input(facts: Self.facts(), skipped: [day])) == nil)
        #expect(NotificationPlan.snooze(.wrap, day: day, input: Self.input(facts: Self.facts(sealed: true))) == nil)
        #expect(NotificationPlan.snooze(.source, day: day, input: Self.input(facts: Self.facts())) == nil)
        #expect(NotificationPlan.snooze(.inbox, day: day, input: Self.input(facts: Self.facts())) == nil)
    }

    @Test func aPendingSnoozeStaysInTheScheduleUntilItIsDueOrNoLongerWanted() throws {
        let day = Self.day("2026-09-24")
        let snooze = try #require(NotificationPlan.snooze(.wrap, day: day, input: Self.input(now: "2026-09-24T17:31:00+05:30", facts: Self.facts())))
        func ids(_ input: NotificationInput) -> [String] { NotificationPlan.scheduled(input).map(\.id) }
        let pending = Self.input(now: "2026-09-24T17:40:00+05:30", facts: Self.facts(), snoozed: [snooze])
        #expect(ids(pending).contains("wrap.2026-09-24.later"))
        // Sealed meanwhile: it goes. Fired already: it goes.
        let sealed = Self.input(now: "2026-09-24T17:40:00+05:30", facts: Self.facts(sealed: true), snoozed: [snooze])
        #expect(!ids(sealed).contains("wrap.2026-09-24.later"))
        let done = Self.input(now: "2026-09-24T18:02:00+05:30", facts: Self.facts(), snoozed: [snooze])
        #expect(!ids(done).contains("wrap.2026-09-24.later"))
        // A plan snooze goes once the plan is committed.
        let planSnooze = try #require(NotificationPlan.snooze(.plan, day: day, input: Self.input(facts: Self.facts())))
        let committed = Self.input(now: "2026-09-24T09:10:00+05:30", facts: Self.facts(committed: true), snoozed: [planSnooze])
        #expect(!ids(committed).contains("plan.2026-09-24.later"))
    }

    // MARK: Applying the schedule

    @Test func onlyWhatChangedIsAddedAndWhatIsGoneIsRemoved() throws {
        let input = Self.input(now: "2026-09-24T09:00:00+05:30", wrap: ["16:00", "17:30"], facts: Self.facts())
        let before = NotificationPlan.scheduled(input)
        // Nothing changed: nothing to do.
        #expect(NotificationPlan.changes(from: before, to: before) == NotificationChanges(add: [], remove: []))
        // Another item is logged: only today's two bodies are rewritten.
        let after = NotificationPlan.scheduled(Self.input(now: "2026-09-24T09:05:00+05:30", wrap: ["16:00", "17:30"], facts: Self.facts(items: 8)))
        let changes = NotificationPlan.changes(from: before, to: after)
        #expect(changes.add.map(\.id) == ["wrap.2026-09-24.16:00", "wrap.2026-09-24.17:30"])
        #expect(changes.remove.isEmpty)
        // The day is sealed: today's go, and nothing else is touched.
        let sealed = NotificationPlan.scheduled(Self.input(now: "2026-09-24T09:05:00+05:30", wrap: ["16:00", "17:30"], facts: Self.facts(sealed: true, items: 8)))
        let gone = NotificationPlan.changes(from: after, to: sealed)
        #expect(gone.add.isEmpty)
        #expect(gone.remove.sorted() == ["wrap.2026-09-24.16:00", "wrap.2026-09-24.17:30"])
    }

    @Test func aMorningRescheduleMovesTheWindowByOneWorkday() {
        let thursday = NotificationPlan.scheduled(Self.input(now: "2026-09-24T05:00:00+05:30"))
        let friday = NotificationPlan.scheduled(Self.input(now: "2026-09-25T05:00:00+05:30"))
        let changes = NotificationPlan.changes(from: thursday, to: friday)
        #expect(changes.remove == ["wrap.2026-09-24.17:30"])
        #expect(changes.add.map(\.id) == ["wrap.2026-10-05.17:30"])
    }

    // MARK: What a button does

    @Test func eachButtonAndATapGoWhereTheSpecSays() {
        let day = "2026-09-24"
        func reply(_ category: NotificationCategory, _ response: NotificationResponse, day: String? = day) -> NotificationReply? {
            NotificationPlan.reply(category: category.rawValue, response: response, day: day)
        }
        let thursday = Self.day(day)
        #expect(reply(.plan, .action(NotificationAction.planNow.rawValue)) == .route(.plan(thursday)))
        #expect(reply(.plan, .tap) == .route(.plan(thursday)))
        #expect(reply(.plan, .action(NotificationAction.planLater.rawValue)) == .snooze(.plan, thursday))
        #expect(reply(.plan, .action(NotificationAction.planSkip.rawValue)) == .skipToday(thursday))
        #expect(reply(.wrap, .action(NotificationAction.wrapUp.rawValue)) == .route(.wrapUp(thursday)))
        #expect(reply(.wrap, .tap) == .route(.wrapUp(thursday)))
        #expect(reply(.wrap, .action(NotificationAction.wrapLater.rawValue)) == .snooze(.wrap, thursday))
        #expect(reply(.source, .action(NotificationAction.openSources.rawValue), day: nil) == .route(.sources))
        #expect(reply(.source, .tap, day: nil) == .route(.sources))
        #expect(reply(.inbox, .tap, day: nil) == .route(.inbox))
    }

    @Test func aDismissalAnUnknownButtonOrAMissingDayDoNothing() {
        #expect(NotificationPlan.reply(category: "PLAN", response: .dismiss, day: "2026-09-24") == nil)
        #expect(NotificationPlan.reply(category: "PLAN", response: .action("SOMETHING_ELSE"), day: "2026-09-24") == nil)
        #expect(NotificationPlan.reply(category: "NOPE", response: .tap, day: "2026-09-24") == nil)
        #expect(NotificationPlan.reply(category: "PLAN", response: .tap, day: nil) == nil)
        #expect(NotificationPlan.reply(category: "WRAP", response: .tap, day: "not a day") == nil)
        // A button of another category is not that category's.
        #expect(NotificationPlan.reply(category: "SOURCE", response: .action(NotificationAction.planNow.rawValue), day: nil) == nil)
    }

    // MARK: Facts and the store

    @Test func theFactsComeFromTheDayThatWasRead() {
        let day = Day(date: "2026-09-24", tz: "Asia/Kolkata", sealedAt: "2026-09-24T17:40:00+05:30")
        let tasks = [
            PlanTask(id: "a", day: "2026-09-24", position: 1, title: "Write ADR", origin: .selfReported, plannedAt: "2026-09-24T09:00:00+05:30"),
            PlanTask(id: "b", day: "2026-09-24", position: 2, title: "Review RFC", origin: .selfReported, status: .done, plannedAt: "2026-09-24T09:00:00+05:30"),
        ]
        let state = DayState(day: Self.day("2026-09-24"), view: DayView(day: day, tasks: tasks, entries: [], presence: []), streak: nil)
        let facts = NotificationFacts(state: state, reviewsWaiting: 2)
        #expect(facts.day == Self.day("2026-09-24"))
        #expect(facts.sealed)
        #expect(facts.open == ["Write ADR"])
        // Read without the rest of the day: what the context holds is unknown, not zero.
        #expect(facts.committed == false)
        #expect(facts.carried == nil)
        #expect(facts.items == nil)
        #expect(facts.reviewsWaiting == 2)
    }
}
