import CadenceCore
import Foundation
import Testing

@testable import CadenceUI

/// `←` and `→` in Today (docs/SPEC.md section 4.8): earlier days only, read only, and back to the live day on leaving.
@MainActor @Suite struct DayBrowserTests {
    typealias Home = DayStoreLoaderTests.Home
    static let today = LocalDate(year: 2026, month: 9, day: 21)!

    /// Counts the reads it is asked for; every read fails, which is enough for the stepping rules.
    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var asked: [LocalDate] = []
        var days: [LocalDate] { lock.withLock { asked } }
        func read(_ day: LocalDate) { lock.withLock { asked.append(day) } }
    }

    static func browser(_ counter: Counter = Counter()) -> DayBrowser {
        DayBrowser(read: { day in
            counter.read(day)
            return nil
        })
    }

    func until(timeout: Duration = .seconds(15), _ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }

    @Test func stepsBackAndForwardAndNeverPastToday() {
        let days = Self.browser()
        #expect(days.shown == nil)
        days.step(by: 1, today: Self.today)
        #expect(days.shown == nil, "there is nothing after today")
        days.step(by: -1, today: Self.today)
        #expect(days.shown == Self.today.adding(days: -1))
        days.step(by: -1, today: Self.today)
        #expect(days.shown == Self.today.adding(days: -2))
        days.step(by: 1, today: Self.today)
        #expect(days.shown == Self.today.adding(days: -1))
        days.step(by: 1, today: Self.today)
        #expect(days.shown == nil, "stepping onto today is the live day")
        #expect(days.load == .loading)
        days.step(by: 1, today: Self.today)
        #expect(days.shown == nil)
    }

    @Test func withoutAReaderTodayStaysLive() {
        let days = DayBrowser()
        #expect(!days.canStep)
        days.step(by: -1, today: Self.today)
        #expect(days.shown == nil)
    }

    @Test func readsOnArrivalAndAgainOnRefreshOnlyWhileShown() async {
        let counter = Counter()
        let days = Self.browser(counter)
        days.refresh()
        days.step(by: -1, today: Self.today)
        #expect(await until { days.reads == 1 })
        #expect(counter.days == [Self.today.adding(days: -1)])
        if case .failed = days.load {} else { Issue.record("a read that fails is the error state, not old numbers") }
        days.refresh()
        #expect(await until { days.reads == 2 })
        #expect(counter.days.count == 2)
        days.backToToday()
        days.refresh()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(counter.days.count == 2, "the live day is read by the day model, not here")
    }

    @Test func escapeAndBackToTodayReturnToTheLiveDay() {
        let days = Self.browser()
        days.step(by: -3, today: Self.today)
        #expect(days.shown(today: Self.today) == Self.today.adding(days: -3))
        days.backToToday()
        #expect(days.shown == nil)
        #expect(days.shown(today: Self.today) == nil)
    }

    @Test func theDayBoundaryReturnsToTheLiveDay() {
        let days = Self.browser()
        days.step(by: -1, today: Self.today)
        let tomorrow = Self.today.adding(days: 1)
        // Before anyone is told, the day picked under yesterday's live day is not shown under today's.
        #expect(days.shown(today: tomorrow) == nil)
        days.follow(today: Self.today)
        #expect(days.shown == Self.today.adding(days: -1), "the same live day keeps the earlier day")
        days.follow(today: tomorrow)
        #expect(days.shown == nil)
    }

    @Test func leavingTodayReturnsToTheLiveDay() {
        let navigation = WindowNavigation(days: Self.browser())
        navigation.days.step(by: -1, today: Self.today)
        navigation.open(.today)
        #expect(navigation.days.shown != nil, "opening Today again keeps the day")
        navigation.open(.log)
        #expect(navigation.days.shown == nil)
        navigation.open(.today)
        navigation.days.step(by: -1, today: Self.today)
        navigation.openSettings(pane: nil)
        #expect(navigation.days.shown == nil)
    }

    // MARK: Read only

    @Test func anEarlierDayIsReadOnly() {
        var input = TodayTests.input(.planned)
        #expect(input.actions == [.wrapUp])
        input.past = TodayInput.Past(graceOpen: false)
        #expect(input.actions.isEmpty)
        #expect(input.heroVoice.hasPrefix("Showing Thursday 29 Oct"))
        #expect(input.foundLabel == "Found on Thursday")
        #expect(input.unplannedTitle == "Nothing planned or logged")
    }

    @Test func anEarlierDayInsideItsGraceWindowKeepsItsWrapUp() {
        var input = TodayTests.input(.planned)
        input.past = TodayInput.Past(graceOpen: true)
        #expect(input.actions == [.wrapUpYesterday("Thursday")])
        #expect(input.actions.first?.title == "Wrap up Thursday")
        input.day.sealedAt = "18:12"
        #expect(input.actions.isEmpty, "a sealed day has nothing left to wrap up")
    }

    @Test func anEarlierDayNeverShowsTheYesterdayCard() {
        var input = TodayTests.input(.yesterdayOpen)
        #expect(input.yesterday != nil)
        input.past = TodayInput.Past()
        #expect(input.yesterday == nil)
        #expect(input.yesterdaySummary == nil)
    }

    @Test func anEarlierDaysLengthEndsAtItsLastActivity() {
        var input = TodayTests.input(.inRhythm)
        input.lastActivity = TodaySpecimen.at("17:11")
        input.past = TodayInput.Past()
        #expect(input.dayLength.rows.last == ["Length", "7h 30m"])
        #expect(input.dayLength.rows[1] == ["Last activity", "17:11"])
    }

    @Test func anEarlierDaysBandNamesTheDayAndReadsAgainstTheUsualDay() throws {
        var input = TodayTests.input(.inRhythm)
        #expect(try #require(input.band).lastName == "Today")
        input.past = TodayInput.Past()
        let band = try #require(input.band)
        #expect(band.lastName == "Thursday")
        #expect(band.byNow == nil, "a finished day is not read against this time of day")
        #expect(band.voice.hasPrefix("7 items logged on Thursday."))
        #expect(band.rows(locale: Locale(identifier: "en_GB")).last?.first == "Thursday")
    }

    @Test func todayShowsTheEarlierDayFromTheStore() async throws {
        let home = Home()
        defer { home.remove() }
        let app = try await AppStateTests.make(home)
        let days = DayBrowser(reader: StoreReader(location: .found(home.roots), clock: DayStoreLoaderTests.FixedClock()))
        let task = try #require(app.context?.plan.first)
        app.tick(task)
        defer { app.undoTick() }

        days.step(by: -1, today: app.today)
        #expect(await until { days.reads == 1 })
        #expect(days.model?.day == app.today.adding(days: -1))
        let sunday = try #require(TodayInput(app: app, days: days))
        #expect(sunday.past != nil)
        #expect(sunday.day.date == app.today.adding(days: -1))
        #expect(sunday.plan.isEmpty)
        #expect(sunday.pendingTask == nil, "today's waiting tick is not on an earlier day")
        #expect(sunday.actions.isEmpty)

        // Whatever the store says next is read again while the day is shown.
        days.refresh()
        #expect(await until { days.reads == 2 })

        days.step(by: 1, today: app.today)
        let live = try #require(TodayInput(app: app, days: days))
        #expect(live.past == nil)
        #expect(live.day.date == app.today)
        #expect(live.pendingTask == task.id)
    }
}

extension DayBrowser {
    /// The day as last read, for tests.
    fileprivate var model: DayState? {
        if case .loaded(let state) = load { return state }
        return nil
    }
}
