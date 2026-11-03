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

    // MARK: Reopening (T4.18)

    /// A clock the test sets, so a seal and a reopening land at the minute it says.
    final class StepClock: CadenceCore.Clock, @unchecked Sendable {
        private let lock = NSLock()
        private var current: Date

        init(_ start: Date) { current = start }

        func now() -> Date { lock.withLock { current } }
        func set(_ date: Date) { lock.withLock { current = date } }
    }

    /// The history a real ledger gives 29 Oct 2026, written with seals and reopenings at the given Kolkata times, so the
    /// line is read from what `Journal.dayHistory` returns and nothing is made up.
    static func history(_ items: [(DayHistoryItem.Kind, String)]) throws -> [DayHistoryItem] {
        let home = Home()
        defer { home.remove() }
        let config = Config.defaults(timezone: "Asia/Kolkata")
        let clock = StepClock(TodaySpecimen.at("08:00"))
        let ids = ULIDGenerator(clock: clock, random: SeededRandomSource(seed: 7))
        let store = try SQLiteStore(path: home.roots.database.path, clock: clock, ids: ids, projector: LedgerProjector())
        let journal = try Journal(store: store, config: config, clock: clock, ids: ids)
        for (kind, time) in items {
            clock.set(TodaySpecimen.at(time))
            switch kind {
            case .sealed: _ = try journal.seal(TodayTests.date, actor: .app)
            case .reopened: _ = try journal.reopen(day: TodayTests.date, actor: .app)
            }
        }
        return try journal.dayHistory(TodayTests.date)
    }

    @Test func aSealedDayOffersReopenAndAnOpenOneDoesNot() {
        var input = TodayTests.input(.sealed)
        #expect(input.canReopen)
        input.past = TodayInput.Past()
        #expect(input.canReopen, "an earlier day reached with the arrow keys can be reopened too")
        #expect(input.actions.isEmpty, "and stays read only until it is")
        #expect(!TodayTests.input(.planned).canReopen)
        #expect(!TodayTests.input(.storeProblem).canReopen)
        var past = TodayTests.input(.planned)
        past.past = TodayInput.Past()
        #expect(!past.canReopen)
    }

    @Test func aReopenedEarlierDayCanBeChangedAndWrappedUp() {
        var input = TodayTests.input(.planned)
        input.past = TodayInput.Past(graceOpen: false, reopened: true)
        #expect(input.actions == [.wrapUp])
        #expect(input.actions.first?.title == "Wrap up")
        #expect(input.isEditable && input.canLog, "ticks and a log field, as on the live day")
        #expect(!input.canReopen)
        // Inside its grace window it is wrapped up as any open day is, by the same sheet.
        input.past = TodayInput.Past(graceOpen: true, reopened: true)
        #expect(input.actions == [.wrapUp])
        // An earlier day that was never reopened stays read only, open or not.
        input.past = TodayInput.Past(graceOpen: false)
        #expect(!input.isEditable && !input.canLog)
        #expect(input.actions.isEmpty)
        // The live day is editable until it is sealed, and takes a line after the seal as it always did.
        input.past = nil
        #expect(input.isEditable && input.canLog)
        input.day.sealedAt = "18:12"
        #expect(!input.isEditable && input.canLog)
    }

    @Test func theHistoryLineSaysEachSealAndReopening() throws {
        var input = TodayTests.input(.sealed)
        // One seal is the day as it always was: the story's own sentence.
        input.history = try Self.history([(.sealed, "13:15")])
        #expect(input.historyLine == nil)
        #expect(input.heroSentence == input.story.sentence)
        input.history = try Self.history([(.sealed, "13:15"), (.reopened, "14:02"), (.sealed, "15:30")])
        #expect(input.historyLine == "Sealed 13:15, reopened 14:02, sealed again 15:30")
        #expect(input.heroSentence == "Sealed 13:15, reopened 14:02, sealed again 15:30")
        #expect(input.heroVoice.hasSuffix("Sealed 13:15, reopened 14:02, sealed again 15:30"))
        input.history = try Self.history([(.sealed, "13:15"), (.reopened, "14:02"), (.sealed, "15:30"), (.reopened, "16:00"), (.sealed, "17:10")])
        #expect(input.historyLine == "Sealed 13:15, reopened 14:02, sealed again 15:30, reopened 16:00, sealed again 17:10")
        // Only the last five say their time, so the line fits the hero.
        input.history = try Self.history([
            (.sealed, "09:00"), (.reopened, "09:30"), (.sealed, "10:00"), (.reopened, "10:30"), (.sealed, "11:00"), (.reopened, "11:30"),
            (.sealed, "12:00"),
        ])
        #expect(input.historyLine == "Sealed 10:00, reopened 10:30, sealed again 11:00, reopened 11:30, sealed again 12:00")
    }

    @Test func aReopenedDayThatIsNotSealedAgainSaysSoAndWhatToDo() throws {
        var input = TodayTests.input(.planned)
        input.history = try Self.history([(.sealed, "13:15"), (.reopened, "14:02")])
        #expect(input.historyLine == "Reopened at 14:02. Wrap up again when you're done.")
        #expect(input.heroSentence == "Reopened at 14:02. Wrap up again when you're done.")
        // The latest reopening names the time.
        input.history = try Self.history([(.sealed, "13:15"), (.reopened, "14:02"), (.sealed, "15:30"), (.reopened, "16:00")])
        #expect(input.historyLine == "Reopened at 16:00. Wrap up again when you're done.")
        // A day with no history has none to say.
        input.history = []
        #expect(input.historyLine == nil)
    }

    @Test func theHistoryLineAndTheButtonKeepTheCopyRules() throws {
        var input = TodayTests.input(.sealed)
        var lines = [TodayInput.reopenTitle]
        input.history = try Self.history([(.sealed, "13:15"), (.reopened, "14:02"), (.sealed, "15:30")])
        lines.append(input.historyLine ?? "")
        input.history = try Self.history([(.sealed, "13:15"), (.reopened, "14:02")])
        lines.append(input.historyLine ?? "")
        #expect(TodayInput.reopenTitle == "Reopen day")
        for line in lines {
            #expect(!line.isEmpty && CopyRules.allows(line), "\(line)")
        }
    }

    @Test func anEarlierDayIsReopenedWrittenAndReadAgainFromTheStore() async throws {
        let home = Home()
        defer { home.remove() }
        let app = try await AppStateTests.make(home)
        // The clock's day is a Monday, so three days back is the Friday before: a workday, as the plan card needs.
        let yesterday = app.today.adding(days: -3)
        let journal = try home.journal()
        _ = try journal.log(LogRequest(text: "Reviewed the RFC", date: yesterday), actor: .cli, origin: .selfReported)
        _ = try journal.seal(yesterday, actor: .cli)

        let days = DayBrowser(reader: StoreReader(location: .found(home.roots), clock: DayStoreLoaderTests.FixedClock()))
        days.step(by: -3, today: app.today)
        #expect(await until { days.reads == 1 })
        var input = try #require(TodayInput(app: app, days: days))
        #expect(input.day.date == yesterday && input.canReopen)
        #expect(input.past?.reopened == false && !input.isEditable)
        #expect(days.reopenedDay(today: app.today) == nil)
        #expect(input.historyLine == nil)

        #expect(await app.reopen(day: yesterday))
        days.refresh()
        #expect(await until { days.reads == 2 })
        input = try #require(TodayInput(app: app, days: days))
        #expect(input.past?.reopened == true && input.isEditable && !input.canReopen)
        #expect(input.actions == [.wrapUp])
        #expect(input.historyLine?.hasPrefix("Reopened at ") == true)
        #expect(days.reopenedDay(today: app.today) == yesterday)
        #expect(days.shownPlan(today: app.today) == input.plan)

        // A line logged on it lands on that day, not marked as after a wrap-up.
        let entry = try #require(await app.log("Reviewed the other RFC", day: days.reopenedDay(today: app.today)))
        #expect(entry.day == yesterday.description && !entry.afterSeal)
        days.refresh()
        #expect(await until { days.reads == 3 })
        input = try #require(TodayInput(app: app, days: days))
        #expect(input.found.map(\.title).contains("Reviewed the other RFC"))

        // Sealed again, it is read only once more and its history says both seals.
        _ = try journal.seal(yesterday, actor: .app)
        days.refresh()
        #expect(await until { days.reads == 4 })
        input = try #require(TodayInput(app: app, days: days))
        #expect(input.canReopen && !input.isEditable && input.actions.isEmpty)
        #expect(input.history.map(\.kind) == [.sealed, .reopened, .sealed])
        #expect(days.reopenedDay(today: app.today) == nil)
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
