import CadenceCore
import Foundation
import Testing

@testable import CadenceUI

/// What the dot and the Pocket read from a day, and that what is unknown stays nil (docs/SPEC.md section 6.6).
@Suite struct DayStateTests {
    static let today = LocalDate("2026-09-21")!

    static func task(_ id: String, _ status: TaskStatus, position: Int64 = 1) -> PlanTask {
        PlanTask(
            id: id, day: today.description, position: position, title: "Task \(id)", origin: .selfReported, status: status,
            plannedAt: "2026-09-21T09:00:00+05:30")
    }

    static func state(
        tasks: [PlanTask] = [], day: Day = Day(date: today.description, tz: "Asia/Kolkata"), streak: Streak? = nil
    ) -> DayState {
        DayState(day: today, view: DayView(day: day, tasks: tasks, entries: [], presence: []), streak: streak)
    }

    @Test func aDayWithNothingRecordedHasNoInventedValues() {
        let state = Self.state()
        #expect(state.planned == 0)
        #expect(state.resolved == 0)
        #expect(state.resolvedFraction == nil)  // nothing planned: no fraction, not 0 of 0
        #expect(state.startedAt == nil)
        #expect(state.sealedAt == nil)
        #expect(state.isSealed == false)
        #expect(state.streak == nil)
        #expect(state.tasks.isEmpty)
        #expect(state.onCall == false)
        #expect(state.kind == .workday)
        #expect(state.day == Self.today)
    }

    @Test func resolvedOverPlannedCountsEverySettledTask() {
        let state = Self.state(tasks: [
            Self.task("a", .done, position: 1), Self.task("b", .slipped, position: 2), Self.task("c", .dropped, position: 3),
            Self.task("d", .open, position: 4), Self.task("e", .open, position: 5),
        ])
        #expect(state.planned == 5)
        #expect(state.resolved == 3)
        #expect(state.resolvedFraction == 0.6)
    }

    @Test func aTaskCarriedAwayHasLeftTheDay() {
        let state = Self.state(tasks: [Self.task("a", .done), Self.task("b", .moved, position: 2)])
        #expect(state.tasks.map(\.id) == ["a"])
        #expect(state.planned == 1)
        #expect(state.resolved == 1)
        #expect(state.resolvedFraction == 1)
    }

    @Test func timesKindOnCallAndStreakComeFromTheDay() throws {
        let day = Day(
            date: Self.today.description, tz: "Asia/Kolkata", kind: .holiday, firstActivity: "2026-09-21T10:02:00+05:30",
            onCall: true, sealedAt: "2026-09-21T18:30:00+05:30")
        let streak = Streak(current: 19, best: 21)
        let state = Self.state(day: day, streak: streak)
        #expect(state.startedAt == Timestamp.parse("2026-09-21T10:02:00+05:30"))
        #expect(state.sealedAt == Timestamp.parse("2026-09-21T18:30:00+05:30"))
        #expect(state.isSealed)
        #expect(state.onCall)
        #expect(state.kind == .holiday)
        #expect(state.streak == streak)
    }

    @Test func aTimeThatDoesNotParseIsUnknownNotNow() {
        let day = Day(date: Self.today.description, tz: "Asia/Kolkata", firstActivity: "not a time", sealedAt: "")
        let state = Self.state(day: day)
        #expect(state.startedAt == nil)
        #expect(state.sealedAt == nil)
    }

    @Test func failureCopyIsSentenceCaseWithoutDashes() {
        let failure = StoreFailure(CadenceError.io("unable to open database file"))
        for text in [failure.summary, failure.detail] {
            #expect(!text.contains("\u{2013}"))
            #expect(!text.contains("\u{2014}"))
        }
        #expect(failure.summary == "Cadence cannot read its store")
        #expect(failure.detail == "unable to open database file")
    }
}
