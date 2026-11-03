import AppKit
import CadenceCore
import Foundation
import Testing

@testable import CadenceUI

/// What the day clock schedules from a moment in time, and how it reacts to a wake and to zone and clock changes
/// (docs/SPEC.md section 3). 2026-09-21 is a Monday.
@MainActor @Suite struct DayClockTests {
    static let kolkata = TimeZone(identifier: "Asia/Kolkata")!
    static let tokyo = TimeZone(identifier: "Asia/Tokyo")!
    static let london = TimeZone(identifier: "Europe/London")!

    static func at(_ text: String) -> Date { Timestamp.parse(text)! }

    static func input(
        zone: TimeZone = kolkata, workdays: Set<Weekday> = [.mon, .tue, .wed, .thu, .fri], declared: [LocalDate: DayKind] = [:],
        reminders: [Config.Reminder] = Config.defaultReminders, startedAt: Date? = nil, unsealed: LocalDate? = nil
    ) -> DayClockInput {
        DayClockInput(
            zone: zone, rules: DayRules(workdays: workdays, boundary: .standard), declared: declared, reminders: reminders,
            dayStartedAt: startedAt, unsealed: unsealed)
    }

    static func wrap(_ times: String...) -> [Config.Reminder] { times.map { Config.Reminder(kind: .wrap, at: $0) } }

    static func kinds(_ moments: [DayMoment]) -> [DayMoment.Kind] { moments.map(\.kind) }

    // MARK: The boundary

    @Test func theNextBoundaryIsTheNextFourInTheProfileZone() {
        let moments = Self.input().moments(after: Self.at("2026-09-22T10:00:00+05:30"))
        #expect(moments.last == DayMoment(at: Self.at("2026-09-23T04:00:00+05:30"), kind: .boundary))
    }

    @Test func acrossTheBoundaryTheNextOneIsADayLater() {
        let input = Self.input(reminders: [])
        let before = input.moments(after: Self.at("2026-09-23T03:59:30+05:30"))
        #expect(before == [DayMoment(at: Self.at("2026-09-23T04:00:00+05:30"), kind: .boundary)])
        // At the boundary itself the day has turned, so the moment is behind and the next one is tomorrow's.
        let at = input.moments(after: Self.at("2026-09-23T04:00:00+05:30"))
        #expect(at == [DayMoment(at: Self.at("2026-09-24T04:00:00+05:30"), kind: .boundary)])
        // A night owl at 02:00 still belongs to the day before, and its boundary is two hours away.
        let late = input.moments(after: Self.at("2026-09-23T02:00:00+05:30"))
        #expect(late == [DayMoment(at: Self.at("2026-09-23T04:00:00+05:30"), kind: .boundary)])
    }

    @Test func aConfiguredBoundaryMovesTheMoment() {
        var input = Self.input(reminders: [])
        input.rules = DayRules(boundary: DayBoundary(hour: 5, minute: 30)!)
        let moments = input.moments(after: Self.at("2026-09-22T10:00:00+05:30"))
        #expect(moments == [DayMoment(at: Self.at("2026-09-23T05:30:00+05:30"), kind: .boundary)])
    }

    @Test func theBoundaryFollowsTheClockThroughAFallBack() {
        // London falls back on 2026-10-25 at 02:00 local, so 04:00 that morning is 04:00 UTC, not 03:00.
        let moments = Self.input(zone: Self.london, reminders: []).moments(after: Self.at("2026-10-24T20:00:00Z"))
        #expect(moments == [DayMoment(at: Self.at("2026-10-25T04:00:00Z"), kind: .boundary)])
    }

    // MARK: Reminders

    @Test func aReminderAheadIsScheduledAndOnePassedIsNot() {
        let input = Self.input(reminders: Self.wrap("17:30"))
        let ahead = input.moments(after: Self.at("2026-09-22T16:00:00+05:30"))
        #expect(Self.kinds(ahead) == [.wrapReminder("17:30"), .boundary])
        #expect(ahead.first?.at == Self.at("2026-09-22T17:30:00+05:30"))
        let passed = input.moments(after: Self.at("2026-09-22T18:00:00+05:30"))
        #expect(Self.kinds(passed) == [.boundary])
        // At the minute itself it has arrived, so it is not ahead.
        #expect(Self.kinds(input.moments(after: Self.at("2026-09-22T17:30:00+05:30"))) == [.boundary])
    }

    @Test func severalRemindersKeepOnlyThoseAheadInOrder() {
        let input = Self.input(reminders: Self.wrap("18:00", "16:00", "17:30"))
        let moments = input.moments(after: Self.at("2026-09-22T17:00:00+05:30"))
        #expect(Self.kinds(moments) == [.wrapReminder("17:30"), .wrapReminder("18:00"), .boundary])
    }

    @Test func aTimeBeforeTheBoundaryBelongsToTheNextCalendarDate() {
        // 02:00 is the tail of Tuesday's workday, so on Tuesday evening it is ahead and on Wednesday 03:00 it is not.
        let input = Self.input(reminders: Self.wrap("02:00"))
        let evening = input.moments(after: Self.at("2026-09-22T20:00:00+05:30"))
        #expect(evening.first == DayMoment(at: Self.at("2026-09-23T02:00:00+05:30"), kind: .wrapReminder("02:00")))
        let small = input.moments(after: Self.at("2026-09-23T03:00:00+05:30"))
        #expect(Self.kinds(small) == [.boundary])
    }

    @Test func aDeclaredLeaveDayHasNoReminders() {
        let tuesday = LocalDate("2026-09-22")!
        let now = Self.at("2026-09-22T09:30:00+05:30")
        let started = Self.at("2026-09-22T09:00:00+05:30")
        for kind in [DayKind.leavePlanned, .leaveUnplanned, .holiday] {
            let input = Self.input(
                declared: [tuesday: kind], reminders: Config.defaultReminders + Self.wrap("16:00"), startedAt: started)
            #expect(Self.kinds(input.moments(after: now)) == [.boundary], "\(kind)")
        }
        // The next day is its own day and is not affected.
        let wednesday = Self.input(declared: [tuesday: .leavePlanned], reminders: Self.wrap("17:30"))
        #expect(Self.kinds(wednesday.moments(after: Self.at("2026-09-23T10:00:00+05:30"))) == [.wrapReminder("17:30"), .boundary])
    }

    @Test func aWeekendNeverPromptsUnlessItWasDeclaredAWorkday() {
        let saturday = Self.at("2026-09-26T10:00:00+05:30")
        let started = Self.at("2026-09-26T09:00:00+05:30")
        let plain = Self.input(startedAt: started)
        #expect(Self.kinds(plain.moments(after: saturday)) == [.boundary])
        let declared = Self.input(declared: [LocalDate("2026-09-26")!: .workday], startedAt: started)
        #expect(Self.kinds(declared.moments(after: saturday)) == [.wrapReminder("17:30"), .boundary])
    }

    @Test func aMoreWorkdaysConfigurationPromptsOnASaturday() {
        let input = Self.input(workdays: [.mon, .tue, .wed, .thu, .fri, .sat], reminders: Self.wrap("17:30"))
        #expect(Self.kinds(input.moments(after: Self.at("2026-09-26T10:00:00+05:30"))) == [.wrapReminder("17:30"), .boundary])
    }

    // MARK: The plan prompt

    @Test func thePlanPromptIsDayStartPlusItsOffsetOnceTheDayHasStarted() {
        let started = Self.at("2026-09-22T09:00:00+05:30")
        let input = Self.input(reminders: [Config.Reminder(kind: .plan, after: "dayStart+2m")], startedAt: started)
        let moments = input.moments(after: Self.at("2026-09-22T09:01:00+05:30"))
        #expect(moments.first == DayMoment(at: Self.at("2026-09-22T09:02:00+05:30"), kind: .planPrompt))
        // Passed, so nothing is ahead.
        #expect(Self.kinds(input.moments(after: Self.at("2026-09-22T09:03:00+05:30"))) == [.boundary])
        // An hour offset.
        let hour = Self.input(reminders: [Config.Reminder(kind: .plan, after: "dayStart+1h")], startedAt: started)
        #expect(hour.moments(after: Self.at("2026-09-22T09:01:00+05:30")).first?.at == Self.at("2026-09-22T10:00:00+05:30"))
    }

    @Test func thereIsNoPlanPromptBeforeTheDayHasStarted() {
        let input = Self.input(reminders: [Config.Reminder(kind: .plan, after: "dayStart+2m")], startedAt: nil)
        #expect(Self.kinds(input.moments(after: Self.at("2026-09-22T09:01:00+05:30"))) == [.boundary])
    }

    @Test func aDayStartFromAnEarlierDayPromptsNothing() {
        // The model still holds yesterday's first activity just after the boundary, until it has read again.
        let yesterday = Self.at("2026-09-22T23:59:00+05:30")
        let input = Self.input(reminders: [Config.Reminder(kind: .plan, after: "dayStart+5h")], startedAt: yesterday)
        // 04:59 on Wednesday is ahead, but it is Tuesday's start plus five hours, not Wednesday's.
        #expect(Self.kinds(input.moments(after: Self.at("2026-09-23T04:00:30+05:30"))) == [.boundary])
    }

    @Test func aMalformedOffsetIsIgnored() {
        let started = Self.at("2026-09-22T09:00:00+05:30")
        for text in ["2m", "dayStart+", "dayStart+0m", "dayStart+2", "dayStart-2m", "dayStart+12345m"] {
            let input = Self.input(reminders: [Config.Reminder(kind: .plan, after: text)], startedAt: started)
            #expect(Self.kinds(input.moments(after: Self.at("2026-09-22T09:01:00+05:30"))) == [.boundary], "\(text)")
        }
    }

    @Test func aPromptThatWouldLandAfterTheBoundaryIsDropped() {
        let started = Self.at("2026-09-23T03:59:00+05:30")  // still Tuesday's workday
        let input = Self.input(reminders: [Config.Reminder(kind: .plan, after: "dayStart+2m")], startedAt: started)
        #expect(Self.kinds(input.moments(after: Self.at("2026-09-23T03:59:30+05:30"))) == [.boundary])
    }

    // MARK: The grace window

    @Test func theGraceWindowOfTheLastUnsealedWorkdayCloses() {
        let monday = LocalDate("2026-09-21")!
        let input = Self.input(reminders: [], unsealed: monday)
        let moments = input.moments(after: Self.at("2026-09-22T10:00:00+05:30"))
        // Monday can be sealed until 23:59 on Tuesday, so the window has closed from the start of Wednesday.
        #expect(Self.kinds(moments) == [.graceClosed(monday), .boundary])
        #expect(abs(moments[0].at.timeIntervalSince(Self.at("2026-09-23T00:00:00+05:30"))) < 0.01)
        // Behind us, nothing to schedule.
        #expect(Self.kinds(input.moments(after: Self.at("2026-09-23T00:30:00+05:30"))) == [.boundary])
        #expect(Self.kinds(Self.input(reminders: []).moments(after: Self.at("2026-09-22T10:00:00+05:30"))) == [.boundary])
    }

    @Test func theCloseIsTheFirstInstantTheRuleCallsTheWindowClosed() {
        let monday = LocalDate("2026-09-21")!
        let input = Self.input(reminders: [], unsealed: monday)
        let close = input.moments(after: Self.at("2026-09-22T10:00:00+05:30"))[0].at
        let rules = input.rules
        #expect(rules.graceClosed(for: monday, at: close, in: input.zone))
        #expect(!rules.graceClosed(for: monday, at: close.addingTimeInterval(-0.01), in: input.zone))
    }

    // MARK: Order

    @Test func momentsComeInTimeOrderWithTheBoundaryLast() {
        let monday = LocalDate("2026-09-21")!
        let started = Self.at("2026-09-22T09:00:00+05:30")
        let input = Self.input(
            reminders: [Config.Reminder(kind: .plan, after: "dayStart+2m")] + Self.wrap("17:30", "16:00"), startedAt: started,
            unsealed: monday)
        let moments = input.moments(after: Self.at("2026-09-22T09:00:30+05:30"))
        #expect(Self.kinds(moments) == [.planPrompt, .wrapReminder("16:00"), .wrapReminder("17:30"), .graceClosed(monday), .boundary])
        #expect(moments.map(\.at) == moments.map(\.at).sorted())
    }

    // MARK: Zone change

    @Test func aZoneChangeMovesEveryMomentAndCanMoveTheDay() {
        let now = Self.at("2026-09-22T10:00:00+05:30")  // 04:30 UTC
        let home = Self.input(zone: Self.kolkata, reminders: Self.wrap("17:30")).moments(after: now)
        let away = Self.input(zone: Self.tokyo, reminders: Self.wrap("17:30")).moments(after: now)
        #expect(home.first?.at == Self.at("2026-09-22T17:30:00+05:30"))
        #expect(away.first?.at == Self.at("2026-09-22T17:30:00+09:00"))
        #expect(away.last?.at == Self.at("2026-09-23T04:00:00+09:00"))
        // 00:30 in Kolkata is 04:00 in Tokyo: the same instant is a different workday there.
        let later = Self.at("2026-09-23T00:30:00+05:30")  // 04:00 in Tokyo
        #expect(Self.input(zone: Self.kolkata).day(at: later) == LocalDate("2026-09-22")!)
        #expect(Self.input(zone: Self.tokyo).day(at: later) == LocalDate("2026-09-23")!)
    }

    // MARK: Profile and state

    @Test func theInputIsBuiltFromTheConfigAndTheDayRead() {
        var config = Config.defaults(timezone: "Asia/Tokyo")
        config.reminders = [Config.Reminder(kind: .plan, after: "dayStart+2m"), Config.Reminder(kind: .wrap, at: "16:00")]
        let started = "2026-09-22T09:00:00+09:00"
        let day = Day(date: "2026-09-22", tz: "Asia/Tokyo", kind: .leavePlanned, firstActivity: started)
        let state = DayState(day: LocalDate("2026-09-22")!, view: DayView(day: day, tasks: [], entries: [], presence: []), streak: nil)
        let input = DayClockInput(config: config, state: state)
        #expect(input.zone == Self.tokyo)
        #expect(input.rules == DayRules(config: config))
        #expect(input.reminders == config.reminders)
        #expect(input.dayStartedAt == Self.at(started))
        #expect(input.declared == [LocalDate("2026-09-22")!: .leavePlanned])
        #expect(input.unsealed == nil)
        // With no state read yet there is no start, no declaration and nothing unsealed.
        let empty = DayClockInput(config: config, state: nil)
        #expect(empty.dayStartedAt == nil && empty.declared.isEmpty && empty.unsealed == nil)
    }

    @Test func anOpenGraceWindowOfThePreviousDayIsTheOneWatched() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("cadence-ui-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let roots = FileRoots(home: folder)
        let config = Config.defaults(timezone: "Asia/Kolkata")
        try ConfigStore.save(config, to: roots.config)
        let clock = ManualClock(Self.at("2026-09-25T10:00:00+05:30"))  // a Friday
        let ids = ULIDGenerator(clock: clock, random: SeededRandomSource(seed: 7))
        let store = try SQLiteStore(path: roots.database.path, clock: clock, ids: ids, projector: LedgerProjector())
        let journal = try Journal(store: store, config: config, clock: clock, ids: ids)
        _ = try journal.log(LogRequest(text: "Reviewed the ACME RFC", kind: .docReviewed), actor: .cli, origin: .selfReported)
        let loader = DayStoreLoader(location: .found(roots), clock: clock)
        func state() throws -> DayState {
            guard case .loaded(let state) = loader.load() else { throw CadenceError.notFound("no state") }
            return state
        }

        // Saturday morning is still Friday's grace window, and Friday is the last workday of a day that counts none.
        clock.set(Self.at("2026-09-26T10:00:00+05:30"))
        #expect(try state().context?.previous?.graceOpen == true)
        #expect(DayClockInput(config: config, state: try state()).unsealed == LocalDate("2026-09-25")!)
        // Monday: the window closed at the end of Saturday, so there is nothing left to watch.
        clock.set(Self.at("2026-09-28T10:00:00+05:30"))
        #expect(try state().context?.previous?.graceOpen == false)
        #expect(DayClockInput(config: config, state: try state()).unsealed == nil)
    }

    // MARK: The clock itself

    @MainActor final class FakeTimer: DayClockTimer {
        private(set) var armedAt: Date?
        private(set) var armCount = 0
        private var handler: (@MainActor () -> Void)?

        func arm(at date: Date, now: Date, handler: @escaping @MainActor () -> Void) {
            armedAt = date
            armCount += 1
            self.handler = handler
        }

        func cancel() {
            armedAt = nil
            handler = nil
        }

        /// The timer going off.
        func fire() {
            let handler = handler
            self.handler = nil
            armedAt = nil
            handler?()
        }
    }

    /// A clock wired to fakes: a manual clock, a fake timer, private notification centers and an input the test can change.
    @MainActor final class Rig {
        let now: ManualClock
        let timer = FakeTimer()
        let center = NotificationCenter()
        let workspace = NotificationCenter()
        var input: DayClockInput
        private(set) var events: [DayClock.Event] = []
        private(set) var clock: DayClock!

        init(now: String, input: DayClockInput) {
            self.now = ManualClock(DayClockTests.at(now))
            self.input = input
            clock = DayClock(
                clock: self.now, timer: timer, center: center, workspaceCenter: workspace,
                inputs: { [unowned self] in self.input }, onEvent: { [unowned self] in self.events.append($0) })
        }

        func take() -> [DayClock.Event] {
            defer { events = [] }
            return events
        }
    }

    /// Waits on the main actor, which stays free to deliver notifications, until `condition` holds.
    func until(timeout: Duration = .seconds(15), _ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }

    @Test func startingArmsTheTimerAtTheEarliestMomentAndSaysNothing() {
        let rig = Rig(now: "2026-09-22T16:00:00+05:30", input: Self.input(reminders: Self.wrap("17:30")))
        #expect(rig.timer.armedAt == nil)
        rig.clock.start()
        #expect(rig.timer.armedAt == Self.at("2026-09-22T17:30:00+05:30"))
        #expect(rig.events.isEmpty)
    }

    @Test func eachMomentIsFiredOnceAndTheTimerMovesOn() {
        let rig = Rig(now: "2026-09-22T16:00:00+05:30", input: Self.input(reminders: Self.wrap("17:30")))
        rig.clock.start()
        rig.now.set(Self.at("2026-09-22T17:30:00.020+05:30"))  // a timer goes off a few milliseconds late
        rig.timer.fire()
        #expect(rig.take() == [.moment(DayMoment(at: Self.at("2026-09-22T17:30:00+05:30"), kind: .wrapReminder("17:30")))])
        #expect(rig.timer.armedAt == Self.at("2026-09-23T04:00:00+05:30"))
        rig.now.set(Self.at("2026-09-23T04:00:00.010+05:30"))
        rig.timer.fire()
        #expect(rig.take() == [.moment(DayMoment(at: Self.at("2026-09-23T04:00:00+05:30"), kind: .boundary))])
        // Wednesday has its own 17:30 ahead.
        #expect(rig.timer.armedAt == Self.at("2026-09-23T17:30:00+05:30"))
    }

    @Test func aTimerThatGoesOffEarlyFiresNothingAndWaitsAgain() {
        let rig = Rig(now: "2026-09-22T16:00:00+05:30", input: Self.input(reminders: Self.wrap("17:30")))
        rig.clock.start()
        rig.now.set(Self.at("2026-09-22T17:29:59.999+05:30"))
        rig.timer.fire()
        #expect(rig.events.isEmpty)
        #expect(rig.timer.armedAt == Self.at("2026-09-22T17:30:00+05:30"))
    }

    @Test func momentsThatCameDueBeforeARecomputeAreNotLost() {
        let rig = Rig(now: "2026-09-23T03:59:59+05:30", input: Self.input(reminders: []))
        rig.clock.start()
        // The day is read again a moment after the boundary, before the timer has gone off.
        rig.now.set(Self.at("2026-09-23T04:00:00.002+05:30"))
        rig.clock.recompute()
        #expect(rig.take() == [.moment(DayMoment(at: Self.at("2026-09-23T04:00:00+05:30"), kind: .boundary))])
        #expect(rig.timer.armedAt == Self.at("2026-09-24T04:00:00+05:30"))
    }

    @Test func newInformationMovesTheTimer() {
        let rig = Rig(now: "2026-09-22T09:01:00+05:30", input: Self.input(reminders: [Config.Reminder(kind: .plan, after: "dayStart+2m")]))
        rig.clock.start()
        #expect(rig.timer.armedAt == Self.at("2026-09-23T04:00:00+05:30"))
        // The presence engine records the first activity, the model reads it, and the clock is asked again.
        rig.input.dayStartedAt = Self.at("2026-09-22T09:00:00+05:30")
        rig.clock.recompute()
        #expect(rig.timer.armedAt == Self.at("2026-09-22T09:02:00+05:30"))
        #expect(rig.events.isEmpty)
    }

    @Test func sleepingThroughTheBoundaryIsNoticedOnWake() async {
        let rig = Rig(now: "2026-09-22T23:00:00+05:30", input: Self.input(reminders: Self.wrap("17:30")))
        rig.clock.start()
        #expect(rig.timer.armedAt == Self.at("2026-09-23T04:00:00+05:30"))
        // The Mac sleeps at 23:00 and wakes at 07:00. The timer is not fired by us; the wake is the signal.
        rig.now.set(Self.at("2026-09-23T07:00:00+05:30"))
        rig.workspace.post(name: NSWorkspace.didWakeNotification, object: nil)
        #expect(await until { rig.events.count >= 2 })
        #expect(
            rig.take() == [
                .changed(.wake),
                .moment(DayMoment(at: Self.at("2026-09-23T04:00:00+05:30"), kind: .boundary)),
            ])
        // Wednesday's reminder is ahead again and the next boundary is Thursday's.
        #expect(rig.timer.armedAt == Self.at("2026-09-23T17:30:00+05:30"))
    }

    @Test func aWakeWithinTheSameDayReplaysNothingThatPassedInTheSleep() async {
        let rig = Rig(now: "2026-09-22T16:00:00+05:30", input: Self.input(reminders: Self.wrap("16:30", "17:30")))
        rig.clock.start()
        rig.now.set(Self.at("2026-09-22T17:00:00+05:30"))  // asleep through 16:30
        rig.workspace.post(name: NSWorkspace.didWakeNotification, object: nil)
        #expect(await until { !rig.events.isEmpty })
        #expect(rig.take() == [.changed(.wake)])
        #expect(rig.timer.armedAt == Self.at("2026-09-22T17:30:00+05:30"))
    }

    @Test func aZoneChangeIsReportedAndEveryMomentIsRecomputed() async {
        let rig = Rig(now: "2026-09-22T10:00:00+05:30", input: Self.input(zone: Self.kolkata, reminders: Self.wrap("17:30")))
        rig.clock.start()
        #expect(rig.timer.armedAt == Self.at("2026-09-22T17:30:00+05:30"))
        rig.input = Self.input(zone: Self.tokyo, reminders: Self.wrap("17:30"))
        rig.center.post(name: .NSSystemTimeZoneDidChange, object: nil)
        #expect(await until { !rig.events.isEmpty })
        #expect(rig.take() == [.changed(.timeZone)])
        #expect(rig.timer.armedAt == Self.at("2026-09-22T17:30:00+09:00"))
    }

    @Test func aClockChangeBackwardsRearmsFromTheNewTime() async {
        let rig = Rig(now: "2026-09-22T18:00:00+05:30", input: Self.input(reminders: Self.wrap("17:30")))
        rig.clock.start()
        #expect(rig.timer.armedAt == Self.at("2026-09-23T04:00:00+05:30"))
        rig.now.set(Self.at("2026-09-22T16:00:00+05:30"))  // the clock was set back two hours
        rig.center.post(name: .NSSystemClockDidChange, object: nil)
        #expect(await until { !rig.events.isEmpty })
        #expect(rig.take() == [.changed(.clock)])
        #expect(rig.timer.armedAt == Self.at("2026-09-22T17:30:00+05:30"))
    }

    @Test func aNewCalendarDayIsReportedWithoutAMoment() async {
        let rig = Rig(now: "2026-09-22T23:59:59+05:30", input: Self.input(reminders: []))
        rig.clock.start()
        rig.now.set(Self.at("2026-09-23T00:00:01+05:30"))
        rig.center.post(name: .NSCalendarDayChanged, object: nil)
        #expect(await until { !rig.events.isEmpty })
        // Midnight is not the workday boundary, so the workday has not turned.
        #expect(rig.take() == [.changed(.calendarDay)])
    }

    @Test func stoppingCancelsTheTimerAndIgnoresLaterSignals() async {
        let rig = Rig(now: "2026-09-22T16:00:00+05:30", input: Self.input(reminders: Self.wrap("17:30")))
        rig.clock.start()
        rig.clock.stop()
        #expect(rig.timer.armedAt == nil)
        rig.workspace.post(name: NSWorkspace.didWakeNotification, object: nil)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(rig.events.isEmpty)
        rig.clock.recompute()
        #expect(rig.timer.armedAt == nil)
    }

    @Test func startingTwiceObservesOnce() async {
        let rig = Rig(now: "2026-09-22T16:00:00+05:30", input: Self.input(reminders: Self.wrap("17:30")))
        rig.clock.start()
        rig.clock.start()
        rig.workspace.post(name: NSWorkspace.didWakeNotification, object: nil)
        #expect(await until { !rig.events.isEmpty })
        try? await Task.sleep(for: .milliseconds(30))
        #expect(rig.take() == [.changed(.wake)])
    }

    @Test func followingTheModelRecomputesWhenItPublishes() async {
        final class Loader: DayLoading, @unchecked Sendable {
            let result: DayLoad
            init(_ result: DayLoad) { self.result = result }
            func load() -> DayLoad { result }
        }
        let started = "2026-09-22T09:00:00+05:30"
        let day = Day(date: "2026-09-22", tz: "Asia/Kolkata", firstActivity: started)
        let state = DayState(day: LocalDate("2026-09-22")!, view: DayView(day: day, tasks: [], entries: [], presence: []), streak: nil)
        let model = DayModel(loader: Loader(.loaded(state)))
        let config = Config.defaults(timezone: "Asia/Kolkata")
        let timer = FakeTimer()
        let clock = DayClock(
            clock: ManualClock(Self.at("2026-09-22T09:01:00+05:30")), timer: timer, center: NotificationCenter(),
            workspaceCenter: NotificationCenter(), inputs: { DayClockInput(config: config, state: model.state) },
            onEvent: { _ in })
        clock.start()
        clock.follow(model)
        #expect(timer.armedAt == Self.at("2026-09-22T17:30:00+05:30"))  // nothing read yet: no plan prompt
        model.reload()
        #expect(await until { timer.armedAt == Self.at("2026-09-22T09:02:00+05:30") })
    }
}
