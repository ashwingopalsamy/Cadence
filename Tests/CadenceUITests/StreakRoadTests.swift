import CadenceCore
import Foundation
import Testing

@testable import CadenceUI

/// The streak road and its milestones (docs/SPEC.md sections 5.4 and 5.6).
@MainActor @Suite struct StreakRoadTests {
    final class FakeStore: MilestoneStore {
        var saved: Set<Int> = []
        var writes = 0
        func played() -> Set<Int> { saved }
        func record(_ played: Set<Int>) {
            saved = played
            writes += 1
        }
    }

    final class Speaker {
        var sounds: [CadenceSound] = []
    }

    static func tracker(_ store: FakeStore, _ speaker: Speaker) -> MilestoneTracker {
        MilestoneTracker(store: store) { speaker.sounds.append($0) }
    }

    // MARK: the road

    @Test func theRoadRunsToTheNextMilestoneWithEveryStopOnIt() {
        let road = StreakRoadFigures(current: 19, paused: 2)
        #expect(road.passed == [5, 10])
        #expect(road.next == 20)
        #expect(road.length == 20)
        #expect(road.stops == [5, 10, 20])
        #expect(road.summary == "19 workdays sealed in a row. Milestones passed: 5 and 10. The next is 20. Days off paused it 2 times and never broke it.")
        #expect(
            road.table.rows == [
                ["Sealed in a row", "19"], ["Milestones passed", "5, 10"], ["Next milestone", "20"], ["Days off inside the run", "2"],
            ])
    }

    @Test func aRoadAtTheStartAndPastTheLastMilestone() {
        let start = StreakRoadFigures(current: 0)
        #expect(start.length == 5)
        #expect(start.passed.isEmpty)
        #expect(start.summary == "0 workdays sealed in a row. The first milestone is 5.")
        #expect(start.table.rows[1] == ["Milestones passed", "-"])

        let long = StreakRoadFigures(current: 230)
        #expect(long.next == nil)
        #expect(long.length == 230)
        #expect(long.stops == StreakRoadFigures.milestones)
        #expect(long.summary == "230 workdays sealed in a row. Milestones passed: 5, 10, 20, 50, 100 and 200.")
        #expect(long.table.rows[2] == ["Next milestone", "-"])
    }

    @Test func theRoadIsOneUnbrokenLineFromStartToEnd() {
        let road = StreakRoad.Road(width: 420)
        let start = road.point(at: 0)
        let end = road.point(at: 1)
        #expect(start.x < end.x)
        #expect(end.y > start.y)
        // Small steps along the road never jump.
        var previous = start
        for step in 1...200 {
            let point = road.point(at: CGFloat(step) / 200)
            #expect(hypot(point.x - previous.x, point.y - previous.y) <= road.total / 200 + 0.5)
            previous = point
        }
        #expect(abs(road.path.boundingRect.maxX - (420 - StreakRoad.Metrics.head / 2)) < 0.5)
    }

    @Test func everyRoadSentenceKeepsTheCopyRules() {
        for current in [0, 1, 4, 5, 19, 20, 199, 200, 230] {
            let road = StreakRoadFigures(current: current, paused: current % 3)
            #expect(CopyRules.allows(road.summary))
            #expect(!road.summary.lowercased().contains("best"))
        }
    }

    // MARK: milestones

    @Test func eachMilestonePlaysOnce() {
        let store = FakeStore()
        let speaker = Speaker()
        let tracker = Self.tracker(store, speaker)
        #expect(tracker.reached(4) == nil)
        #expect(tracker.reached(5) == 5)
        #expect(tracker.reached(5) == nil)
        #expect(tracker.reached(9) == nil)
        #expect(tracker.reached(10) == 10)
        #expect(speaker.sounds == [.streakMilestone, .streakMilestone])
        #expect(store.saved == [5, 10])
    }

    @Test func aStreakFirstSeenPastSeveralMilestonesPlaysOnceAndMarksThemAll() {
        let store = FakeStore()
        let speaker = Speaker()
        #expect(Self.tracker(store, speaker).reached(23) == 20)
        #expect(speaker.sounds == [.streakMilestone])
        #expect(store.saved == [5, 10, 20])
    }

    @Test func aBrokenRunThatReachesAMilestoneAgainDoesNotReplayIt() {
        let store = FakeStore()
        let speaker = Speaker()
        let tracker = Self.tracker(store, speaker)
        tracker.reached(12)
        tracker.reached(0)
        tracker.reached(5)
        tracker.reached(10)
        #expect(speaker.sounds.count == 1)
    }

    @Test func playedMilestonesSurviveANewTracker() {
        let store = FakeStore()
        let speaker = Speaker()
        Self.tracker(store, speaker).reached(50)
        #expect(Self.tracker(store, speaker).reached(50) == nil)
        #expect(Self.tracker(store, speaker).reached(100) == 100)
        #expect(speaker.sounds.count == 2)
        #expect(store.writes == 2)
    }

    @Test func theDefaultsStoreKeepsItsOwnKey() throws {
        let suite = "cadence-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = DefaultsMilestoneStore(defaults: defaults)
        #expect(store.played().isEmpty)
        store.record([10, 5])
        #expect(DefaultsMilestoneStore(defaults: defaults).played() == [5, 10])
        #expect(defaults.array(forKey: "in.ashwingopalsamy.cadence.insights.streakMilestonesPlayed") as? [Int] == [5, 10])
    }
}
