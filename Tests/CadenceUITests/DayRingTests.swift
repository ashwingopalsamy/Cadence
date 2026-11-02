import CadenceCore
import Testing

@testable import CadenceUI

@MainActor @Suite struct DayRingTests {
    @Test func segmentsLeaveTheTopGapAndEvenGaps() {
        let layout = DayRingLayout(tasks: [.done, .slipped, .open], beads: [:])
        #expect(layout.segments.first?.start == 7)
        #expect(abs((layout.segments.last?.end ?? 0) - 353) < 0.001)
        #expect(abs(layout.segments[1].start - layout.segments[0].end - 6) < 0.001)
    }

    @Test func aCarriedTaskHasLeftTheRing() {
        #expect(DayRingLayout(tasks: [.done, .moved, .open], beads: [:]).segments.map(\.status) == [.done, .open])
    }

    @Test func beadsKeepTheFixedFamilyOrderAndAIStaysSmall() {
        let layout = DayRingLayout(tasks: [], beads: [.ai: 9, .review: 1, .delivery: 2, .leadership: 1, .presence: 4])
        #expect(layout.beads.map(\.family) == [.delivery, .delivery, .review, .leadership, .ai, .ai, .ai])
    }

    @Test func familiesAreSetApart() {
        let beads = DayRingLayout(tasks: [], beads: [.delivery: 2, .review: 1]).beads
        #expect(beads[1].angle - beads[0].angle == 13)
        #expect(beads[2].angle - beads[1].angle == 20)
    }

    @Test func aFullRingTightensAndNeverWrapsPastTheStart() {
        let beads = DayRingLayout(tasks: [], beads: [.delivery: 24, .review: 24, .initiative: 24, .ownership: 24, .leadership: 24, .ai: 24]).beads
        #expect(beads.count == 123)
        #expect((beads.last?.angle ?? 0) < 13 + 326)
    }

    @Test func theCentreSaysDoneOverPlannedAndUnknownIsNotZero() {
        func ring(_ tasks: [TaskStatus]) -> DayRingView { DayRingView(tasks: tasks, beads: [:], sealed: false, size: 240) }
        #expect(ring([.done, .open, .moved]).centre == "1/2")
        #expect(ring([]).centre == "-")
    }

    @Test func theCaptionNeverDropsBelowTheTypeFloor() {
        #expect(DayRingView(tasks: [.open], beads: [:], sealed: false, size: 240).caption == "planned done")
        #expect(DayRingView(tasks: [], beads: [:], sealed: false, size: 240).caption == nil)
        #expect(DayRingView(tasks: [], beads: [:], sealed: true, size: 240).caption == "sealed")
        #expect(DayRingView(tasks: [.open], beads: [:], sealed: false, size: 120).caption == nil)
        #expect(DayRingView(tasks: [.open], beads: [:], sealed: false, size: 240, style: .compact).caption == nil)
    }

    @Test func voiceOverSaysItInWords() {
        let ring = DayRingView(tasks: [.done, .slipped, .open], beads: [.review: 2, .ai: 1], sealed: true, size: 240)
        #expect(ring.accessibilitySummary == "1 of 3 planned done, 1 slipped, 1 open, 2 review, 1 AI, sealed")
        #expect(DayRingView(tasks: [], beads: [:], sealed: false, size: 240).accessibilitySummary == "Nothing planned")
    }
}
