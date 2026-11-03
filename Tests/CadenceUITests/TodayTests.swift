import CadenceCore
import Foundation
import Testing

@testable import CadenceUI

/// Today in every state (docs/SPEC.md sections 4.6, 5.1, 5.2 and 6.6): the hero's parts, the world, the metric cards
/// with their unknowns, the actions, and discreet mode.
@Suite struct TodayTests {
    static let date = LocalDate(year: 2026, month: 10, day: 29)!
    static let zone = TimeZone(identifier: "Asia/Kolkata")!

    /// A day input that lands in `state`, with a usual range and a little history.
    static func input(_ state: DayStory.State) -> TodayInput {
        var day = DayStory.Input(date: date)
        day.countedWorkdays = 20
        day.usualByNow = 6...8
        day.items = 7
        var failure: StoreFailure.Kind?
        var plan = TodaySpecimen.tasks()
        switch state {
        case .storeProblem:
            day.storeProblem = true
            failure = .corrupt
        case .paused: day.paused = true
        case .sealed: day.sealedAt = "18:12"
        case .editedAfterWrapUp:
            day.sealedAt = "18:12"
            day.lateAdditions = 1
        case .yesterdayOpen:
            day.previous = DayStory.Previous(date: date.adding(days: -1), graceOpen: true, sealedBefore: 3)
            plan = []
            day.items = 0
        case .closedUnsealed:
            day.previous = DayStory.Previous(date: date.adding(days: -1), graceOpen: false, sealedBefore: 3)
            plan = []
            day.items = 0
        case .leave: day.dayOff = .leave
        case .sick: day.dayOff = .sick
        case .holiday: day.dayOff = .holiday
        case .weekend: day.dayOff = .weekend
        case .firstRun: day.firstRun = true
        case .firstSync:
            day.countedWorkdays = 0
            day.importing = DayStory.Import(label: "October", done: 12, total: 20)
        case .learning: day.countedWorkdays = 6
        case .sourceBehind: day.behind = DayStory.Behind(source: "GitHub", lastSync: "13:40")
        case .onCall: day.onCall = true
        case .wrapUpDue: day.wrapUpReminder = "17:30"
        case .nothingLogged:
            day.wrapUpReminder = "17:30"
            day.items = 0
            plan = []
        case .planSettled: plan = plan.map { $0.status == .open ? TodaySpecimen.resolved($0, .done) : $0 }
        case .morning:
            day.items = 0
            plan = []
        case .planned:
            day.items = 0
            plan = plan.map(TodaySpecimen.reopened)
        case .inRhythm: break
        case .moreThanUsual: day.items = 13
        case .fewerThanUsual: day.items = 2
        }
        day.planned = plan.count
        day.resolved = plan.filter { $0.status.isResolved }.count
        day.done = plan.filter { $0.status == .done }.count
        let found = day.items > 0 ? TodaySpecimen.found() : []
        day.aiSessions = found.filter { $0.family == .ai }.count
        return TodayInput(
            day: day, zone: zone, now: TodaySpecimen.at("16:48"), locale: Locale(identifier: "en_GB"),
            firstActivity: day.items > 0 ? TodaySpecimen.at("09:41") : nil, plan: plan, found: found,
            rhythm: TodaySpecimen.rhythm(today: day.items, byNow: UsualRange(low: 6, median: 7, high: 8, days: 20)),
            failure: failure)
    }

    @Test(arguments: DayStory.State.allCases) func everyStateIsReachedAndHasItsWorld(_ state: DayStory.State) {
        let today = Self.input(state)
        #expect(today.state == state)
        #expect(today.world.name == TodayWorld.world(for: state).name)
    }

    @Test func worldsFollowTheSpecTable() {
        let expected: [String: [DayStory.State]] = [
            "lilac": [.firstRun, .firstSync, .learning], "butter": [.morning, .planned], "coral": [.inRhythm, .moreThanUsual],
            "sage": [.fewerThanUsual, .weekend], "mint": [.planSettled], "rose": [.wrapUpDue],
            "forest": [.sealed, .editedAfterWrapUp], "plum": [.yesterdayOpen, .closedUnsealed], "teal": [.onCall],
            "sky": [.leave, .sick, .holiday], "stone": [.paused, .sourceBehind, .nothingLogged], "ink": [.storeProblem],
        ]
        for (world, states) in expected {
            for state in states { #expect(TodayWorld.world(for: state).name == world, "\(state)") }
        }
        #expect(Set(expected.values.flatMap { $0 }).count == DayStory.State.allCases.count)
    }

    @Test(arguments: DayStory.State.allCases) func darkModeDarkensLightWorldsAndKeepsNightWorlds(_ state: DayStory.State) {
        let world = TodayWorld.world(for: state)
        for token in [world.bg, world.a, world.b] {
            if world.isNight {
                #expect(token.dark == token.light)
            } else {
                #expect(token.dark == ColorWorld.darken(token.light))
                #expect(token.dark != token.light)
            }
        }
        #expect(world.ink.dark == world.ink.light)
    }

    @Test func theHeroChartPerState() {
        let none: [DayStory.State] = [.leave, .sick, .holiday, .weekend, .firstRun, .nothingLogged, .storeProblem]
        for state in DayStory.State.allCases {
            let chart = Self.input(state).heroChart
            switch state {
            case _ where none.contains(state): #expect(chart == .none, "\(state)")
            case .learning: #expect(chart == .learning(done: 6, of: 10, caption: "6 of 10 workdays until your usual range appears"))
            case .firstSync: #expect(chart == .learning(done: 12, of: 20, caption: "October backfill"))
            default: #expect(chart == .band, "\(state)")
            }
        }
    }

    @Test func aDayWithNoRangeYetShowsTheLearningDots() {
        var today = Self.input(.sealed)
        today.day.countedWorkdays = 4
        today.rhythm = Rhythm(today: 3, usual: nil, byNow: nil, plan: nil, points: [])
        #expect(today.heroChart == .learning(done: 4, of: 10, caption: "4 of 10 workdays until your usual range appears"))
    }

    @Test func heroParts() {
        let rhythm = Self.input(.inRhythm)
        #expect(rhythm.kicker == "Thursday 29 Oct, first activity 09:41")
        #expect(!rhythm.showsStars)
        #expect(!rhythm.showsCheckSources)
        #expect(rhythm.heroVoice.hasPrefix("Thursday 29 Oct, first activity 09:41. Right in your rhythm."))
        #expect(Self.input(.onCall).kicker.hasSuffix(", on call"))
        #expect(Self.input(.sealed).showsStars)
        #expect(Self.input(.editedAfterWrapUp).showsStars)
        #expect(Self.input(.sourceBehind).showsCheckSources)
        #expect(Self.input(.morning).kicker == "Thursday 29 Oct")
    }

    @Test func layoutPerState() {
        #expect(Self.input(.firstRun).layout == .firstRun)
        #expect(Self.input(.storeProblem).layout == .storeProblem(FailureCopy(.corrupt)))
        for state in [DayStory.State.leave, .sick, .holiday, .weekend] { #expect(Self.input(state).layout == .dayOff) }
        for state in [DayStory.State.morning, .yesterdayOpen, .closedUnsealed, .nothingLogged] {
            #expect(Self.input(state).layout == .unplanned, "\(state)")
        }
        for state in [DayStory.State.inRhythm, .moreThanUsual, .fewerThanUsual, .planSettled, .wrapUpDue, .sealed, .onCall, .paused, .sourceBehind, .planned] {
            #expect(Self.input(state).layout == .full, "\(state)")
        }
    }

    @Test func actionsPerState() {
        #expect(Self.input(.inRhythm).actions == [.wrapUp])
        #expect(Self.input(.wrapUpDue).actions == [.wrapUp])
        #expect(Self.input(.sealed).actions == [.seeRecap])
        #expect(Self.input(.morning).actions == [.planYourDay])
        #expect(Self.input(.closedUnsealed).actions == [.planYourDay])
        #expect(Self.input(.yesterdayOpen).actions == [.planToday])
        #expect(Self.input(.yesterdayOpen).yesterday == "Wednesday")
        #expect(TodayAction.wrapUpYesterday("Wednesday").title == "Wrap up Wednesday")
        #expect(Self.input(.closedUnsealed).yesterday == nil)
        #expect(Self.input(.nothingLogged).actions == [.notWorking, .sealEmpty])
        for state in [DayStory.State.leave, .sick, .holiday, .weekend, .firstRun, .storeProblem] {
            #expect(Self.input(state).actions.isEmpty, "\(state)")
        }
        // The primary is last and is the only one in ink.
        #expect(!TodayAction.sealEmpty.isQuiet && TodayAction.notWorking.isQuiet)
    }

    @Test func unplannedTitles() {
        var morning = Self.input(.morning)
        #expect(morning.unplannedTitle == "You have not planned today yet")
        morning.carried = [TodaySpecimen.task(4, "Update the on-call runbook", origin: .carried)]
        #expect(morning.unplannedTitle == "Pick up where you left off")
        #expect(Self.input(.nothingLogged).unplannedTitle == "Nothing planned or logged")
    }

    @Test func metricValuesFromTheDay() {
        let today = Self.input(.inRhythm)
        let metrics = today.metrics
        #expect(metrics.map(\.label) == ["Delivery", "Reviews", "Day length", "Beyond the plan"])
        #expect(metrics[0].value == [MetricPart("2", "PRs")])
        #expect(metrics[1].value == [MetricPart("3", "reviews")])
        #expect(metrics[2].value == [MetricPart("7", "h"), MetricPart("07", "m")])
        #expect(metrics[2].comparison == "From 09:41")
        #expect(metrics[3].value == [MetricPart("2", "other things")])
        #expect(metrics[3].comparison == "And 2 Claude Code sessions")
        #expect(today.planValue == [MetricPart("2 of 5")])
        // Every chart has its table twin.
        for metric in metrics {
            if case .legend = metric.picture { continue }
            #expect(!metric.rows.isEmpty, "\(metric.label)")
        }
    }

    @Test func unknownIsADashNeverZero() {
        let today = Self.input(.morning)
        for metric in today.metrics { #expect(metric.value == MetricPart.unknown, "\(metric.label)") }
        #expect(today.metrics[2].comparison == "Starts with your first input")
        #expect(today.planValue == MetricPart.unknown)
        #expect(today.weekValue == MetricPart.unknown)
        var leave = Self.input(.leave)
        leave.week = WeekSeals(sealed: 3, workdays: 3)
        #expect(leave.weekValue == [MetricPart("3", "of 3 workdays")])
        let all = today.metrics.flatMap { $0.value.map(\.number) } + today.planValue.map(\.number)
        #expect(!all.contains("0"))
    }

    @Test func aSourceBehindMakesCountsLowerBounds() {
        let today = Self.input(.sourceBehind)
        #expect(today.metrics[0].value == [MetricPart("≥2", "PRs")])
        #expect(today.metrics[1].value == [MetricPart("≥3", "reviews")])
        #expect(today.band?.stale == true)
        #expect(today.band?.voice == "7 items logged today. A usual day is 6 to 8.")
    }

    @Test func theBandReadsAsASentenceAndHasATableTwin() throws {
        let band = try #require(Self.input(.inRhythm).band)
        #expect(band.voice == "7 items logged today. A usual day is 6 to 8, and usually 6 to 8 by 16:48.")
        #expect(band.legend == "Usual day: 6 to 8. Usual by 16:48: 6 to 8. Hollow dots were outside the usual.")
        // Only counted workdays: weekends and the day itself are left out, never drawn as zeros.
        #expect(band.history.count == TodaySpecimen.history.count)
        #expect(!band.history.contains { $0.items == 0 })
        let rows = band.rows(locale: Locale(identifier: "en_GB"))
        #expect(rows.count == band.history.count + 1)
        #expect(rows.last == ["Today", "7", "6 to 8"])
        #expect(rows.first?[2] == "-")
        let quiet = try #require(Self.input(.morning).band)
        #expect(quiet.today == nil)
        #expect(quiet.voice.hasPrefix("Nothing logged yet today."))
    }

    @Test func discreetHidesTitlesTicketsAndTempo() {
        var today = Self.input(.inRhythm)
        today.discreet = true
        let task = today.plan[0]
        #expect(today.title(task.title, index: 0, word: "Task") == "Task 1")
        #expect(today.title("Merged: ledger test clock fix", index: 2) == "Item 3")
        #expect(today.ticket(task) == nil)
        #expect(!today.showsTempo)
        today.discreet = false
        #expect(today.title(task.title, index: 0, word: "Task") == task.title)
        #expect(today.ticket(task) == "ACME-482913")
        #expect(today.showsTempo)
        today.tempoEnabled = false
        #expect(!today.showsTempo)
    }

    @Test func tasksShowTheirStateAndAPendingTickReadsAsDone() {
        var today = Self.input(.inRhythm)
        let slipped = today.plan[2]
        #expect(today.reason(slipped) == "Reprioritised")
        #expect(today.reason(today.plan[0]) == nil)
        let open = today.plan[3]
        today.pendingTask = open.id
        #expect(today.status(of: open) == .done)
        #expect(today.shownDone == 3)
        #expect(today.planValue == [MetricPart("3 of 5")])
    }

    @Test func foundTodayIsNewestFirstWithoutPresence() {
        var today = Self.input(.inRhythm)
        today.found.append(
            Entry(id: "p", day: Self.date.description, kind: .presenceSpan, family: .presence, title: "Day start", origin: .observed))
        #expect(today.shownFound.first?.id == "entry-19")
        #expect(!today.shownFound.contains { $0.family == .presence })
        #expect(today.time(of: today.shownFound[0]) == "16:44")
    }

    @Test func aFoundRowOpensItsFirstLinkAndDiscreetModeHidesItsName() {
        var today = Self.input(.inRhythm)
        let pr = Link(kind: .pr, url: "https://git.example.com/acme/api/pull/88")
        today.found.append(
            Entry(
                id: "linked", day: Self.date.description, kind: .reviewGiven, family: .review, title: "Reviewed", links: [pr],
                origin: .selfReported))
        let linked = today.found.last!
        #expect(today.link(of: linked)?.name == "PR #88")
        #expect(today.link(of: linked)?.openVoice == "Open PR #88")
        #expect(today.link(of: linked)?.url == URL(string: pr.url))
        #expect(today.link(of: today.found[0]) == nil, "an entry without a link has no button")
        // A link the system cannot open is not offered.
        var odd = linked
        odd.links = [Link(kind: .other, url: "file:///etc/hosts")]
        #expect(today.link(of: odd) == nil)
        today.discreet = true
        #expect(today.link(of: linked)?.name == "Link 1")
    }

    @Test func failureCopyFollowsTheTable() {
        #expect(FailureCopy(.busy).title == "Your log is busy right now.")
        #expect(FailureCopy(.busy).primary == .tryAgain && FailureCopy(.busy).secondary == .copyText)
        #expect(FailureCopy(.denied).primary == .showFolder)
        #expect(FailureCopy(.newerSchema).secondary == .quit)
        #expect(FailureCopy(.diskFull).body == "The text is kept until you free some.")
        #expect(FailureCopy(.corrupt).primary == .restoreBackup)
    }

    @Test func copyFollowsTheRules() {
        var lines: [String] = []
        for state in DayStory.State.allCases {
            let today = Self.input(state)
            lines += [today.kicker, today.unplannedTitle] + today.actions.map(\.title)
            lines += today.metrics.flatMap { [$0.label, $0.sentence, $0.comparison, $0.voice] }
            if let band = today.band { lines += [band.voice, band.legend] }
        }
        for kind in [StoreFailure.Kind.busy, .denied, .newerSchema, .diskFull, .corrupt] {
            let copy = FailureCopy(kind)
            lines += [copy.label, copy.title, copy.body, copy.primary.title, copy.secondary.title]
        }
        for line in lines { #expect(CopyRules.allows(line), "\(line)") }
    }

    @Test func widthsAndCompact() {
        #expect(TodayWidth.of(1200) == .wide)
        #expect(TodayWidth.of(900) == .wide)
        #expect(TodayWidth.of(680) == .narrow)
        #expect(TodayWidth.of(479) == .compact)
        #expect(TodayWidth.of(480) == .narrow)
    }

    @Test func windowSectionsAndShortcuts() {
        #expect(WindowSection.tabs.map(\.title) == ["Today", "Log", "Insights", "Recap", "Proof"])
        #expect(WindowSection.tabs.map(\.shortcut) == ["1", "2", "3", "4", "5"])
        #expect(WindowSection.settings.shortcut == ",")
        #expect(WindowSection.inbox.shortcut == nil)
    }

    @Test func everySpecimenStoriesItsName() {
        let expected: [String: DayStory.State] = [
            "In rhythm": .inRhythm, "More than usual": .moreThanUsual, "Fewer than usual": .fewerThanUsual, "Morning": .morning,
            "Plan settled": .planSettled, "Wrap-up due": .wrapUpDue, "Sealed": .sealed, "Yesterday still open": .yesterdayOpen,
            "On call": .onCall, "On leave": .leave, "Capture paused": .paused, "A source is behind": .sourceBehind,
            "Store problem": .storeProblem,
        ]
        for specimen in TodaySpecimen.all { #expect(specimen.input.state == expected[specimen.name], "\(specimen.name)") }
    }
}

/// Today read from a real store through `AppState`.
@MainActor @Suite struct TodayAppStateTests {
    @Test func todayReadsTheAppState() async throws {
        let home = DayStoreLoaderTests.Home()
        defer { home.remove() }
        let app = try await AppStateTests.make(home)
        let today = try #require(TodayInput(app: app))
        #expect(today.story == app.story)
        #expect(today.plan.map(\.title) == ["Write the ADR", "Review the RFC"])
        #expect(today.actions == [.wrapUp])
        app.discreet = true
        #expect(TodayInput(app: app)?.title("Write the ADR", index: 0, word: "Task") == app.title("Write the ADR", index: 0, word: "Task"))
        let task = try #require(today.plan.first)
        app.tick(task)
        #expect(TodayInput(app: app)?.status(of: task) == .done)
        app.undoTick()
    }
}
